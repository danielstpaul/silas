require "socket"

module Silas
  module Mcp
    # A minimal HTTP/1.1 server hosting the MCP Handler for the lifetime of one
    # claude -p subprocess. Deliberately NOT Puma/Rack: the transport claude's
    # MCP client needs (verified in the spike) is plain request/response JSON —
    # one request per connection, application/json, no SSE — so a raw threaded
    # TCPServer is fewer moving parts than embedding an app server in a worker.
    #
    # In-process: the Handler has direct access to the Ledger/models, so no
    # cross-service call is needed and it works on any worker box.
    class Server
      attr_reader :port

      def self.start(turn:, step:, tools:, resolver:, host: Silas.config.agent_sdk_mcp_host)
        token = SecureRandom.hex(16)
        turn.update_columns(mcp_token: token)
        handler = Handler.new(turn: turn, step: step, tools: tools, resolver: resolver, token: token)
        new(handler: handler, turn: turn, token: token, host: host).tap(&:boot)
      end

      def initialize(handler:, turn:, token:, host:)
        @handler = handler
        @turn = turn
        @token = token
        @host = host
      end

      def boot
        @socket = TCPServer.new(@host, 0)
        @port = @socket.addr[1]
        @thread = Thread.new { accept_loop }
        @thread.report_on_exception = false
      end

      def mcp_url = "http://#{@host}:#{@port}/mcp/#{@turn.id}?t=#{@token}"

      # Health-check before spawning claude: a booting server that refuses the
      # first connection gets marked "pending" by the CLI with no retry (spike trap).
      def await_ready!(timeout: 5.0)
        deadline = clock + timeout
        loop do
          TCPSocket.new(@host, @port).close
          return true
        rescue SystemCallError
          raise Silas::Error, "MCP server did not become ready" if clock > deadline

          sleep 0.02
        end
      end

      def stop
        @stopping = true
        @socket&.close
        @thread&.kill
      rescue IOError
        # already closed
      end

      private

      def accept_loop
        loop do
          client = @socket.accept
          Thread.new(client) { |c| handle_connection(c) }
        rescue IOError, Errno::EBADF
          break # socket closed by #stop
        end
      end

      def handle_connection(client)
        request_line = client.gets
        return unless request_line

        method, target, = request_line.split(" ")
        path, query = target.split("?", 2)
        token = query_param(query, "t")

        headers = read_headers(client)
        length = headers["content-length"].to_i
        body = length.positive? ? client.read(length) : ""

        status, payload = dispatch(method, path, token, body)
        write_response(client, status, payload)
      rescue StandardError
        write_response(client, 500, nil) rescue nil
      ensure
        client.close rescue nil
      end

      def dispatch(method, path, token, body)
        return [ 405, nil ] unless method == "POST"

        # ActiveRecord connection per handler thread; released after the call.
        ActiveRecord::Base.connection_pool.with_connection do
          @handler.call(path: path, query_token: token, body: body)
        end
      end

      def read_headers(client)
        headers = {}
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.to_s.strip if value
        end
        headers
      end

      def query_param(query, key)
        return nil unless query

        query.split("&").each do |pair|
          k, v = pair.split("=", 2)
          return v if k == key
        end
        nil
      end

      def write_response(client, status, body)
        reason = { 200 => "OK", 202 => "Accepted", 400 => "Bad Request", 403 => "Forbidden",
                   404 => "Not Found", 405 => "Method Not Allowed", 500 => "Internal Server Error" }[status] || "OK"
        body = body.to_s
        client.write("HTTP/1.1 #{status} #{reason}\r\n")
        client.write("content-type: application/json\r\n")
        client.write("content-length: #{body.bytesize}\r\n")
        client.write("connection: close\r\n\r\n")
        client.write(body)
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
