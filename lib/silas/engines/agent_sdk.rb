module Silas
  module Engines
    # The engine-owned adapter: one `claude -p` subprocess runs a whole agentic
    # turn, calling back into Silas tools over an in-worker HTTP MCP endpoint
    # whose tools/call goes THROUGH the Ledger (exactly-once within the run).
    # The mirror image of :ruby_llm — Claude Code owns the loop; Silas hosts the
    # tools and maps the NDJSON stream onto durable rows.
    #
    # v1 contract (honestly weaker than :ruby_llm): exactly-once WITHIN a run,
    # approval :never tools only, and fail-closed on mid-subprocess worker kill.
    class AgentSdk < Base
      def self.loop_ownership = :engine

      def execute_step(context, &on_event)
        turn = context[:turn]
        Silas::AgentSdk::VersionGuard.assert!(Silas.config.agent_sdk_claude_bin)
        assert_api_key!

        tools = allowed_tools(context[:tools])
        server = Mcp::Server.start(turn: turn, step: context[:step], tools: tools, resolver: Silas.tool_resolver)
        cli = nil
        begin
          server.await_ready!
          cli = build_cli(context, server, tools)
          parser = Silas::AgentSdk::StreamParser.new
          cli.stream do |line|
            parser.ingest(line) do |event|
              persist_session_id!(turn, parser)
              on_event&.call(event)
              ActiveSupport::Notifications.instrument("silas.agent_sdk.event", turn_id: turn.id, type: event.type)
            end
          end
          parser.to_result
        ensure
          cli&.terminate
          server.stop
        end
      end

      private

      def build_cli(context, server, tools)
        Silas::AgentSdk::Cli.new(
          bin: Silas.config.agent_sdk_claude_bin,
          prompt: context[:turn].input,
          system: context[:system],
          model: Silas.config.agent_sdk_model || context[:model],
          mcp_url: server.mcp_url,
          allowed: tools.map { |d| "mcp__silas__#{d['name']}" }
        )
      end

      # v1 excludes approval-gated tools entirely (both tools/list and
      # --allowedTools) — an engine-owned subprocess can't park cheaply.
      def allowed_tools(definitions)
        kept = definitions.select { |d| Silas.tool_resolver.call(d["name"]).approval_policy == :never }
        dropped = definitions.map { |d| d["name"] } - kept.map { |d| d["name"] }
        Rails.logger&.info("silas: :agent_sdk excludes approval-gated tools #{dropped.inspect}") if dropped.any?
        kept
      end

      def persist_session_id!(turn, parser)
        return unless turn.cli_session_id.nil? && parser.session_id.present?

        turn.update_columns(cli_session_id: parser.session_id)
      end

      def assert_api_key!
        return if ENV["ANTHROPIC_API_KEY"].present?

        raise Silas::BootGuardError, ":agent_sdk uses --bare (API-key auth only); set ANTHROPIC_API_KEY"
      end
    end
  end
end
