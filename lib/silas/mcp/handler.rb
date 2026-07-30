require "json"
require "securerandom"

module Silas
  module Mcp
    # JSON-RPC handler for the mounted MCP endpoint. tools/call runs the tool
    # THROUGH the Ledger, so a remote MCP caller gets the same exactly-once and
    # effect-mode semantics as the in-process loop — including approval gates.
    #
    # A gated call does not error and does not hold the connection: it PARKS.
    # The caller gets {"status":"awaiting_approval", ...} naming the
    # invocation, and settles it later through the silas_await_decision tool —
    # minutes or days later, across client disconnects and server deploys,
    # because the park is rows, not process state. Every other MCP client in
    # the field fakes approval with an in-memory button; this endpoint is the
    # seam where a tool call can genuinely wait for a person.
    #
    # Each tools/call gets its own session (channel "mcp") + turn + anchor
    # step. The anchor step is created completed AND terminal, which is what
    # lets the ordinary resume machinery adopt these turns: approve! enqueues
    # AgentLoopJob, whose replay guard skips the model call (step completed),
    # settles the pending invocation through the Ledger, and finishes the turn.
    # No MCP-specific resume path exists — that is the point.
    class Handler
      TOOL_PREFIX = "mcp__silas__".freeze
      AWAIT_TOOL = "silas_await_decision".freeze
      MAX_WAIT_SECONDS = 25 # bound each poll call well under HTTP timeouts
      POLL_INTERVAL = 0.25

      # Returns [http_status, json_string_or_nil].
      def call(body:)
        msg = JSON.parse(body)
        case msg["method"]
        when "initialize"                then ok(msg["id"], initialize_result(msg))
        when "notifications/initialized" then [ 202, nil ]
        when "tools/list"                then ok(msg["id"], { "tools" => tool_list })
        when "tools/call"                then ok(msg["id"], call_tool(msg))
        else rpc_error(msg["id"], -32601, "method not found: #{msg['method']}")
        end
      rescue JSON::ParserError
        [ 400, JSON.generate("error" => "bad json") ]
      end

      private

      def call_tool(msg)
        name = msg.dig("params", "name").to_s.sub(/\A#{Regexp.escape(TOOL_PREFIX)}/, "")
        args = msg.dig("params", "arguments") || {}
        return await_decision(args) if name == AWAIT_TOOL

        invocation = anchor_invocation!(name, args)
        outcome = Silas::Ledger.execute_invocation!(invocation, resolver: Silas.tool_resolver)
        invocation.reload

        if outcome == :parked
          invocation.turn.update!(status: "waiting")
          { "content" => [ text_content(JSON.generate(awaiting_payload(invocation))) ] }
        else
          finish_anchor_turn!(invocation.turn)
          { "content" => [ text_content(JSON.generate(invocation.result)) ] }
        end
      end

      # Poll a parked invocation to settlement. NEVER executes while status is
      # "started" — a concurrently running execution is indistinguishable from
      # a crashed one to the settle path, and re-entering it would park a
      # healthy call in doubt. Execution only proceeds from approved+pending,
      # where the Ledger's claim! CAS guarantees a racing AgentLoopJob and this
      # poll cannot both run the tool.
      def await_decision(args)
        invocation = Silas::ToolInvocation.where(id: args["invocation_id"]).first
        return error_content("unknown invocation #{args['invocation_id'].inspect}") unless invocation
        return error_content("invocation #{invocation.id} did not originate on the MCP endpoint") unless
          invocation.turn.session.channel == "mcp"

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                   [ args.fetch("wait_seconds", MAX_WAIT_SECONDS).to_i, MAX_WAIT_SECONDS ].min
        loop do
          invocation.reload
          case invocation.status
          when "completed", "failed"
            finish_anchor_turn!(invocation.turn)
            return { "content" => [ text_content(JSON.generate(settled_payload(invocation))) ] }
          when "pending"
            if invocation.approval_state == "approved"
              Silas::Ledger.execute_invocation!(invocation, resolver: Silas.tool_resolver)
              next
            end
          end
          # "started": someone is executing right now — poll, never re-enter.
          # "required"/"in_doubt": still waiting on the human.
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            return { "content" => [ text_content(JSON.generate(awaiting_payload(invocation))) ] }
          end

          sleep POLL_INTERVAL
        end
      end

      # One session+turn+anchor step per call. instructions_snapshot is
      # pre-set so Instructions.snapshot! (idempotent on presence) never
      # renders agent instructions for a turn that has no model in it.
      def anchor_invocation!(name, args)
        session = Silas::Session.create!(channel: "mcp",
                                         metadata: { "mcp" => { "tool" => name } })
        turn = Silas::Turn.create!(
          session: session, index: 0, status: "running",
          input: JSON.generate("tool" => name, "arguments" => args),
          instructions_snapshot: "hosted MCP tools/call — no model turn",
          definitions_snapshot: { "tools" => [], "final_answer" => nil }
        )
        step = Silas::Step.create!(
          turn: turn, index: 0, status: "completed", terminal: true,
          response_blocks: [ { "type" => "tool_call", "id" => "mcp", "name" => name, "arguments" => args } ]
        )
        Silas::ToolInvocation.create!(
          step: step, turn: turn,
          tool_call_id: SecureRandom.uuid, # never fed to a provider; uniqueness is all that matters
          tool_name: name, arguments: args, effect_mode: effect_mode_for(name)
        )
      end

      # The worker finishes these turns in production (approve! enqueues the
      # loop, whose replay path settles and finalizes). This CAS covers the
      # await-executed path so a workerless caller still sees the turn settle;
      # losing the race to the job is fine — both write "completed".
      def finish_anchor_turn!(turn)
        claimed = Silas::Turn.where(id: turn.id, status: %w[running waiting queued])
                             .update_all(status: "completed", finished_at: Time.current,
                                         updated_at: Time.current)
        turn.reload if claimed == 1
      end

      def awaiting_payload(invocation)
        { "status" => invocation.status == "in_doubt" ? "in_doubt" : "awaiting_approval",
          "invocation_id" => invocation.id,
          "tool" => invocation.tool_name,
          "approval_state" => invocation.approval_state,
          "expires_at" => invocation.approval_expires_at&.iso8601,
          "await_with" => { "tool" => AWAIT_TOOL,
                            "arguments" => { "invocation_id" => invocation.id } } }
      end

      def settled_payload(invocation)
        { "status" => invocation.status,
          "approval_state" => invocation.approval_state,
          "decided_by" => invocation.approved_by,
          "result" => invocation.result }
      end

      def effect_mode_for(name)
        tool = Silas.tool_resolver.call(name)
        tool.respond_to?(:effect_mode) ? tool.effect_mode.to_s : "at_most_once"
      end

      def tool_list
        Silas.tool_definitions.map { |d| mcp_tool(d) } + [ await_tool_definition ]
      end

      def await_tool_definition
        { "name" => AWAIT_TOOL,
          "description" => "Poll a parked Silas tool call until a person settles it. " \
                           "Returns the final result once approved (executed exactly once), " \
                           "the denial once declined, or the still-waiting status after " \
                           "wait_seconds (max #{MAX_WAIT_SECONDS}s per call — call again; the park " \
                           "holds for days and survives restarts and deploys).",
          "inputSchema" => {
            "type" => "object",
            "properties" => {
              "invocation_id" => { "type" => "integer", "description" => "From the awaiting_approval payload" },
              "wait_seconds" => { "type" => "integer", "description" => "How long this poll may block (capped at #{MAX_WAIT_SECONDS})" }
            },
            "required" => [ "invocation_id" ]
          } }
      end

      def mcp_tool(definition)
        { "name" => definition["name"], "description" => definition["description"],
          "inputSchema" => definition["input_schema"] }
      end

      def initialize_result(msg)
        { "protocolVersion" => msg.dig("params", "protocolVersion") || "2025-06-18",
          "capabilities" => { "tools" => {} },
          "serverInfo" => { "name" => "silas", "version" => Silas::VERSION } }
      end

      def text_content(text) = { "type" => "text", "text" => text }

      def error_content(message)
        { "isError" => true, "content" => [ text_content(message) ] }
      end

      def ok(id, result)
        [ 200, JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result) ]
      end

      def rpc_error(id, code, message)
        [ 200, JSON.generate("jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message }) ]
      end
    end
  end
end
