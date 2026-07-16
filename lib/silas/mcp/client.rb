require "json"
require "net/http"
require "securerandom"

module Silas
  module Mcp
    # JSON-RPC 2.0 over MCP Streamable HTTP — the CLIENT half of Handler/Server,
    # used by connections to call remote MCP servers. Stateless per operation
    # (fresh initialize each call) so it's replay-safe. Net::HTTP only.
    class Client
      PROTOCOL_VERSION = "2025-06-18".freeze

      def initialize(url:, headers: {}, open_timeout: 5, read_timeout: 30)
        @uri = URI(url)
        @headers = headers
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def list_tools
        with_session { |sid| rpc("tools/list", {}, session: sid).fetch("tools") }
      end

      # An MCP application error comes back as a normal result with isError=true
      # (the remote tool ran and errored) — returned so the model can react. Only
      # JSON-RPC/transport failures raise.
      def call_tool(name, arguments)
        with_session { |sid| rpc("tools/call", { "name" => name, "arguments" => arguments }, session: sid) }
      end

      private

      def with_session
        _, headers = post(rpc_body("initialize",
                                   "protocolVersion" => PROTOCOL_VERSION, "capabilities" => {},
                                   "clientInfo" => { "name" => "silas", "version" => Silas::VERSION }))
        sid = headers["mcp-session-id"]
        post(JSON.generate("jsonrpc" => "2.0", "method" => "notifications/initialized"), session: sid)
        yield sid
      end

      def rpc(method, params, session:)
        parsed, = post(rpc_body(method, params), session: session)
        raise Error, "MCP #{method} error: #{parsed['error']}" if parsed && parsed["error"]

        parsed && parsed["result"]
      end

      def rpc_body(method, params)
        JSON.generate("jsonrpc" => "2.0", "id" => SecureRandom.uuid, "method" => method, "params" => params)
      end

      def post(body, session: nil)
        req = Net::HTTP::Post.new(@uri)
        req["content-type"] = "application/json"
        req["accept"] = "application/json, text/event-stream"
        req["mcp-protocol-version"] = PROTOCOL_VERSION
        req["mcp-session-id"] = session if session
        @headers.each { |k, v| req[k] = v } # secret injection lives here
        req.body = body
        res = http.request(req)
        raise Error, "MCP HTTP #{res.code}" unless res.code.start_with?("2")

        [ parse_payload(res), res.each_header.to_h ]
      end

      def parse_payload(res)
        return nil if res.body.to_s.empty?

        if res["content-type"].to_s.include?("text/event-stream")
          data = res.body.each_line.select { |l| l.start_with?("data:") }.last
          return data && JSON.parse(data.delete_prefix("data:").strip)
        end
        JSON.parse(res.body)
      end

      def http
        @http ||= Net::HTTP.new(@uri.host, @uri.port).tap do |h|
          h.use_ssl = @uri.scheme == "https"
          h.open_timeout = @open_timeout
          h.read_timeout = @read_timeout
        end
      end
    end
  end
end
