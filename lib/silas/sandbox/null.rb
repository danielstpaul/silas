module Silas
  module Sandbox
    # The default: code execution is off. run_code isn't even advertised to the
    # model unless a real sandbox is configured, so this only fires on direct
    # misconfiguration — and it fails loud (SandboxDisabledError is a Silas::Error,
    # so the Ledger propagates it rather than silently failing the invocation).
    class Null
      def enabled? = false

      def run(_command, files: {}, timeout: nil)
        raise SandboxDisabledError,
              "code execution is disabled (config.sandbox = :none). " \
              "Set config.sandbox = :docker (and config.sandbox_image) to run untrusted commands."
      end
    end
  end
end
