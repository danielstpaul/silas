require "rails_helper"

RSpec.describe "the sandbox seam" do
  after { Silas.reset_configuration! }

  describe "Silas.resolved_sandbox" do
    it "defaults to Null (code exec disabled)" do
      expect(Silas.resolved_sandbox).to be_a(Silas::Sandbox::Null)
      expect(Silas.sandbox_enabled?).to be(false)
    end

    it "builds a Docker sandbox when configured" do
      Silas.configure { |c| c.sandbox = :docker; c.sandbox_image = "ruby:3.3-slim" }
      expect(Silas.resolved_sandbox).to be_a(Silas::Sandbox::Docker)
      expect(Silas.sandbox_enabled?).to be(true)
    end

    it "accepts a custom sandbox object" do
      custom = Object.new
      Silas.configure { |c| c.sandbox = custom }
      expect(Silas.resolved_sandbox).to eq(custom)
    end
  end

  describe "Sandbox::Null" do
    it "fails loud when a command is run" do
      expect { Silas::Sandbox::Null.new.run("echo hi") }
        .to raise_error(Silas::SandboxDisabledError, /disabled/)
    end
  end

  describe "Sandbox::Docker" do
    subject(:sandbox) do
      Silas::Sandbox::Docker.new(image: "ruby:3.3-slim", runner: fake_runner)
    end

    let(:captured) { [] }
    let(:fake_runner) do
      ->(argv, timeout:, name:) { captured << { argv: argv, timeout: timeout }; [ "hello\n", "", 0 ] }
    end

    it "requires an image" do
      expect { Silas::Sandbox::Docker.new(image: "") }.to raise_error(Silas::SandboxError, /image is required/)
    end

    it "builds a locked-down docker run argv (no network, read-only, dropped caps)" do
      argv = sandbox.docker_argv("echo hi", name: "silas-sbx-abc")
      expect(argv).to include("run", "--rm", "--network", "none", "--read-only",
                              "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "ruby:3.3-slim")
      expect(argv.last(3)).to eq([ "/bin/sh", "-c", "echo hi" ])
    end

    it "runs via the injected runner and returns a Result" do
      result = sandbox.run("echo hi", timeout: 10)
      expect(result.stdout).to eq("hello\n")
      expect(result.success?).to be(true)
      expect(captured.first[:timeout]).to eq(10)
      expect(captured.first[:argv]).to include("ruby:3.3-slim")
    end

    it "refuses to run inside a ledger transaction (must be at_most_once)" do
      Silas::Ledger.instance_variable_set(:@in_txn_test, true)
      allow(Silas::Ledger).to receive(:in_transaction?).and_return(true)
      expect { sandbox.run("echo hi") }.to raise_error(Silas::SandboxError, /at_most_once/)
    end
  end

  describe "the run_code tool" do
    it "is advertised only when a sandbox is configured" do
      Silas::Registry.install!(root: DummyApp.root) # dummy has sandbox :none
      expect(Silas.tool_definitions.map { |d| d["name"] }).not_to include("run_code")

      Silas.configure { |c| c.sandbox = :docker; c.sandbox_image = "x" }
      Silas::Registry.install!(root: DummyApp.root)
      expect(Silas.tool_definitions.map { |d| d["name"] }).to include("run_code")
    end

    it "runs a command through the resolved sandbox" do
      fake = Object.new
      fake.define_singleton_method(:run) { |cmd, **| Silas::Sandbox::Result.new(stdout: "42\n", stderr: "", exit_status: 0) }
      Silas.configure { |c| c.sandbox = fake }
      tool = Silas::Tools::RunCode.new
      expect(tool.call(command: "echo 42")).to eq("stdout" => "42\n", "stderr" => "", "exit_status" => 0)
    end
  end
end
