module Silas
  module AgentSdk
    # The adapter wraps an external CLI whose JSON stream can shift between
    # versions, so pin a tested range and fail loudly outside it.
    module VersionGuard
      module_function

      def assert!(bin, requirement: Silas.config.agent_sdk_cli_version_range)
        version = detect(bin)
        raise Silas::Error, "could not determine `#{bin}` version (is the Claude CLI installed?)" if version.nil?

        unless Gem::Requirement.new(requirement.split(",").map(&:strip)).satisfied_by?(Gem::Version.new(version))
          raise Silas::Error, "claude CLI #{version} is outside the tested range (#{requirement}); pin or upgrade"
        end
        version
      end

      def detect(bin)
        out = `#{bin} --version 2>/dev/null`
        out[/\d+\.\d+\.\d+/]
      rescue StandardError
        nil
      end
    end
  end
end
