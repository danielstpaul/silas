module Silas
  # A Sandbox runs a command in isolation and returns its captured output.
  # Duck-typed like the engine seam: #run(command, files:, timeout:) -> Result,
  # #enabled?. Default is Null (code execution off). :docker is the interim
  # adapter — honestly weaker than eve's per-agent microVM (needs Docker present,
  # container isolation not a VM), but real isolation for untrusted/model code.
  module Sandbox
    Result = Struct.new(:stdout, :stderr, :exit_status, keyword_init: true) do
      def success? = exit_status.to_i.zero?
    end
  end
end

require "silas/sandbox/null"
require "silas/sandbox/docker"
