require "rails_helper"
require "hermetic"

# The two-gem story: a Hermetic backend drops into config.sandbox unchanged.
# Silas resolves the instance as-is, run_code registers off the backend's own
# enabled?, RunCode reads Hermetic::Result through the same duck-type as the
# built-in adapters, and the ledger guard is auto-armed.
RSpec.describe "hermetic as the Silas sandbox" do
  # Canned runner: hermetic Docker's injectable seam — no Docker needed.
  let(:fake_runner) do
    ->(_argv, **) { [ "4\n", "", 0, false ] }
  end
  let(:backend) { Hermetic.docker(image: "python:3.12-slim", runner: fake_runner) }

  def configure_sandbox!(sandbox)
    Silas.configure do |c|
      c.adapter = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(0))
      c.sandbox = sandbox
    end
    Silas::Registry.install!(root: DummyApp.root)
  end

  it "drops in: enabled, registered, and RunCode reads the Result duck-type" do
    configure_sandbox!(backend)

    expect(Silas.sandbox_enabled?).to be true
    expect(Silas.resolved_sandbox).to be backend
    expect(Silas.tool_definitions.map { |d| d["name"] }).to include("run_code")

    out = Silas::Tools::RunCode.new.call(command: "python -c 'print(2+2)'", timeout: 5)
    expect(out).to eq("stdout" => "4\n", "stderr" => "", "exit_status" => 0)
  end

  it "a disabled hermetic backend (Null) does not register run_code" do
    configure_sandbox!(Hermetic.null)

    expect(Silas.sandbox_enabled?).to be false
    expect(Silas.tool_definitions.map { |d| d["name"] }).not_to include("run_code")
  end

  it "auto-arms the ledger guard: sandbox exec inside a ledger transaction fails loud" do
    configure_sandbox!(backend)
    Silas.resolved_sandbox # resolve -> requires hermetic/silas

    # Arm the guard through the real path (0.2 moved its storage to
    # IsolatedExecutionState — the shim reads the public in_transaction?).
    expect {
      Silas::Ledger.send(:guarded_transaction) { backend.run("echo hi") }
    }.to raise_error(Hermetic::Error, /inside a ledger transaction/)
  end

  it "keeps the exit-status contract under timeout (124, not success)" do
    timeout_backend = Hermetic.docker(image: "python:3.12-slim",
                                      runner: ->(_argv, **) { [ "", "", 137, true ] })
    configure_sandbox!(timeout_backend)

    out = Silas::Tools::RunCode.new.call(command: "sleep 60", timeout: 1)
    expect(out["exit_status"]).to eq(124)
  end
end
