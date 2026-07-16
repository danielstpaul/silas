module Silas
  module Tools
    # Built-in, added to the toolset only when a sandbox is configured. Runs a
    # shell command through the configured sandbox. at_most_once! — a sandbox
    # exec is an external effect, so a crash mid-run parks it in-doubt.
    class RunCode < Tool
      description "Run a shell command in an ephemeral, network-isolated sandbox container. " \
                  "Use for untrusted or model-generated code."
      param :command, :string, desc: "Shell command run via /bin/sh -c inside the sandbox."
      param :timeout, :integer, desc: "Max wall-clock seconds before the container is killed."
      at_most_once!

      def self.tool_name = "run_code"

      def call(command:, timeout: nil)
        result = Silas.resolved_sandbox.run(command, timeout: timeout || Silas.config.sandbox_timeout)
        { "stdout" => result.stdout, "stderr" => result.stderr, "exit_status" => result.exit_status }
      end
    end
  end
end
