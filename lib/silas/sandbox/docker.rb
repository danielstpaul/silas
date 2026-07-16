require "securerandom"
require "open3"

module Silas
  module Sandbox
    # Interim adapter: shells to an ephemeral, locked-down `docker run` container
    # (no network, read-only fs, dropped caps, no-new-privileges, memory/cpu/pid
    # limits, host-side timeout). Weaker than a microVM — flag honestly. The argv
    # is a pure function (unit-tested); the exec runner is injectable so the
    # command building is testable without Docker present.
    class Docker
      TIMEOUT_EXIT = 124 # coreutils convention

      def initialize(image:, network: "none", memory: "512m", cpus: "1", pids: 256,
                     workdir: "/workspace", docker_bin: "docker", runner: nil)
        raise SandboxError, "config.sandbox_image is required for :docker" if image.to_s.strip.empty?

        @image = image
        @network = network
        @memory = memory
        @cpus = cpus
        @pids = pids
        @workdir = workdir
        @docker_bin = docker_bin
        @runner = runner || method(:shell_capture)
      end

      def enabled? = true

      def run(command, files: {}, timeout: 30)
        if Silas::Ledger.in_transaction?
          raise SandboxError, "sandbox exec inside a ledger transaction — sandbox-backed tools must be at_most_once!, never transactional!"
        end
        raise SandboxError, "files: is not supported in v1 (deferred)" unless files.empty?

        name = "silas-sbx-#{SecureRandom.hex(6)}"
        out, err, status = @runner.call(docker_argv(command, name: name), timeout: timeout, name: name)
        Result.new(stdout: out, stderr: err, exit_status: status)
      end

      # Pure: command is a single argv element to `sh -c`, never interpolated into
      # a shell string — no injection surface.
      def docker_argv(command, name:)
        [ @docker_bin, "run", "--rm", "--name", name,
          "--network", @network,
          "--memory", @memory, "--cpus", @cpus.to_s, "--pids-limit", @pids.to_s,
          "--read-only", "--tmpfs", @workdir, "--workdir", @workdir,
          "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
          @image, "/bin/sh", "-c", command ]
      end

      private

      def shell_capture(argv, timeout:, name:)
        reaper = Thread.new do
          sleep(timeout)
          system(@docker_bin, "kill", name, out: File::NULL, err: File::NULL)
        end
        out, err, status = Open3.capture3(*argv)
        reaper.kill
        status.termsig ? [ "", "sandbox timed out after #{timeout}s", TIMEOUT_EXIT ] : [ out, err, status.exitstatus ]
      rescue Errno::ENOENT
        raise SandboxError, "docker binary #{@docker_bin.inspect} not found on PATH"
      end
    end
  end
end
