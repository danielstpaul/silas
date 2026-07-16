require "json"
require "securerandom"

module Silas
  module Mcp
    # JSON-RPC handler for the hosted MCP endpoint. tools/call runs the tool
    # THROUGH the Ledger, so the :agent_sdk path gets the same exactly-once and
    # effect-mode semantics as :ruby_llm. Closes over one turn + its anchor step;
    # authenticated by a per-turn bearer token in the URL query.
    class Handler
      TOOL_PREFIX = "mcp__silas__".freeze

      def initialize(turn:, step:, tools:, resolver:, token:)
        @turn = turn
        @step = step
        @tools = tools
        @resolver = resolver
        @token = token
      end

      # Returns [status, json_string_or_nil]. path/query already parsed by the server.
      def call(path:, query_token:, body:)
        return [ 404, error_body("not found") ] unless path == "/mcp/#{@turn.id}"
        return [ 403, error_body("forbidden") ] unless ActiveSupport::SecurityUtils.secure_compare(query_token.to_s, @token)

        msg = JSON.parse(body)
        case msg["method"]
        when "initialize"                then ok(msg["id"], initialize_result(msg))
        when "notifications/initialized" then [ 202, nil ]
        when "tools/list"                then ok(msg["id"], { "tools" => @tools.map { |d| mcp_tool(d) } })
        when "tools/call"                then ok(msg["id"], call_tool(msg))
        else rpc_error(msg["id"], -32601, "method not found: #{msg['method']}")
        end
      rescue JSON::ParserError
        [ 400, error_body("bad json") ]
      end

      private

      def call_tool(msg)
        name = msg.dig("params", "name").to_s.sub(/\A#{Regexp.escape(TOOL_PREFIX)}/, "")
        args = msg.dig("params", "arguments") || {}

        invocation = Silas::ToolInvocation.create!(
          step: @step, turn: @turn,
          tool_call_id: SecureRandom.uuid, # Claude's tool_use.id isn't on the JSON-RPC msg; synth is fine (never fed to a provider)
          tool_name: name, arguments: args, effect_mode: effect_mode_for(name)
        )
        outcome = Silas::Ledger.execute_invocation!(invocation, resolver: @resolver)
        invocation.reload

        if outcome == :parked
          # v1 excludes approval-gated tools; if one slips through, fail loud.
          { "isError" => true, "content" => [ text_content("approval-gated tools are not supported by :agent_sdk") ] }
        else
          { "content" => [ text_content(JSON.generate(invocation.result)) ] }
        end
      end

      def effect_mode_for(name)
        tool = @resolver.call(name)
        tool.respond_to?(:effect_mode) ? tool.effect_mode.to_s : "at_most_once"
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

      def ok(id, result)
        [ 200, JSON.generate("jsonrpc" => "2.0", "id" => id, "result" => result) ]
      end

      def rpc_error(id, code, message)
        [ 200, JSON.generate("jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message }) ]
      end

      def error_body(message) = JSON.generate("error" => message)
    end
  end
end
