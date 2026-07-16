require "json"

module Silas
  module AgentSdk
    # Builds the verified claude -p argv and manages the subprocess. --bare is
    # the API-key-only auth guard (never subscription OAuth); alwaysLoad + a
    # non-zero MCP_TIMEOUT are BOTH mandatory or the single-shot -p turn races
    # ahead of the MCP handshake and never sees the tools (spike trap #1).
    class Cli
      def initialize(bin:, prompt:, system:, model:, mcp_url:, allowed:, resume_session_id: nil)
        @bin = bin
        @prompt = prompt
        @system = system
        @model = model
        @mcp_url = mcp_url
        @allowed = allowed
        @resume_session_id = resume_session_id
      end

      # Spawns claude, yields each stdout line, returns the exit status integer.
      def stream
        @io = IO.popen(env, argv, err: %i[child out], pgroup: true)
        @pid = @io.pid
        @io.each_line { |line| yield line }
        @io.close
        $?.exitstatus
      end

      def terminate
        return unless @pid

        Process.kill("-TERM", @pid)
        Process.kill("-KILL", @pid)
      rescue Errno::ESRCH, Errno::EPERM
        # already gone
      end

      def argv
        args = [ @bin, "-p", @prompt,
                 "--output-format", "stream-json", "--verbose", "--bare",
                 "--mcp-config", mcp_config_json,
                 "--allowedTools", @allowed.join(","),
                 "--model", @model ]
        args += [ "--append-system-prompt", @system ] if @system.present?
        args += [ "--resume", @resume_session_id ] if @resume_session_id.present?
        args
      end

      def mcp_config_json
        JSON.generate("mcpServers" => { "silas" => { "type" => "http", "url" => @mcp_url, "alwaysLoad" => true } })
      end

      def env
        { "ANTHROPIC_API_KEY" => ENV["ANTHROPIC_API_KEY"],
          "MCP_TIMEOUT" => Silas.config.agent_sdk_mcp_timeout_ms.to_s }
      end
    end
  end
end
