require "rails_helper"

RSpec.describe "the :agent_sdk adapter" do
  include ActiveJob::TestHelper

  FAKE_CLAUDE = File.expand_path("../../support/fake_claude", __dir__)

  around do |example|
    original = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "test-key" # --bare needs a key present; fake CLI never calls the real API
    example.run
  ensure
    original.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = original
  end

  describe "boot guard" do
    it "raises when :agent_sdk + :api_key has no ANTHROPIC_API_KEY" do
      ENV.delete("ANTHROPIC_API_KEY")
      expect { Silas.configure { |c| c.engine = :agent_sdk } }
        .to raise_error(Silas::BootGuardError, /--bare/)
    end
  end

  describe "hermetic full loop (real MCP server, fake CLI)" do
    # The MCP server runs on background threads with their own connections, so
    # the durable rows must be committed, not held in a test transaction.
    self.use_transactional_tests = false

    after do
      [ Silas::ToolInvocation, Silas::Step, Silas::Turn, Silas::Session ].each(&:delete_all)
    end

    before do
      Silas::Registry.install!(root: DummyApp.root)
      Silas.configure do |c|
        c.engine = :agent_sdk
        c.agent_sdk_claude_bin = FAKE_CLAUDE
        c.agent_sdk_model = "claude-haiku-4-5-20251001"
        c.isolate_steps = false
      end
      Silas::Registry.install!(root: DummyApp.root) # re-wire after configure
    end

    it "runs a turn through claude -p, executing the tool via the hosted MCP + Ledger" do
      session = Silas.agent.start(input: "use echo_note with 'hello from silas', then say done")
      turn = session.turns.sole

      Silas::AgentLoopJob.perform_now(turn.id)

      turn.reload
      expect(turn.status).to eq("completed")
      expect(turn.cli_session_id).to eq("fake-sess-123")

      invocation = turn.tool_invocations.find_by(tool_name: "echo_note")
      expect(invocation.status).to eq("completed")
      expect(invocation.result).to eq("echo" => "hello from silas") # ran through the Ledger, exactly once

      anchor = turn.steps.find_by(index: 0)
      expect(anchor).to have_attributes(status: "completed", terminal: true)
      final_text = Array(anchor.response_blocks).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
      expect(final_text).to include("done")
    end
  end

  describe "fail-closed on interrupted resume" do
    it "fails the turn (no re-spawn) when a prior run left a CLI session but no completed step" do
      Silas::Registry.install!(root: DummyApp.root)
      session = Silas::Session.create!
      turn = Silas::Turn.create!(session: session, index: 0, input: "x", status: "running",
                                 cli_session_id: "sess-from-dead-run")
      Silas::Step.create!(turn: turn, index: 0) # started, not completed

      expect(Silas::SubprocessRunner.call(turn)).to eq(:failed)
      expect(turn.reload).to have_attributes(status: "failed", failure_reason: "agent_sdk_interrupted")
    end
  end

  describe "AgentLoopJob engine-owned branch" do
    it "uses prepare/run/finalize with a single anchor step" do
      engine = Class.new(Silas::Engines::Base) do
        def self.loop_ownership = :engine
        def execute_step(_context, &_blk)
          Silas::Engines::Result.new(blocks: [ { "type" => "text", "text" => "ok" } ],
                                     tool_calls: [], stop_reason: "success", usage: {})
        end
      end.new

      Silas.configure { |c| c.engine = engine; c.isolate_steps = false }
      Silas::Registry.install!(root: DummyApp.root)
      allow(Silas::StepRunner).to receive(:call).and_call_original

      session = Silas.agent.start(input: "hi")
      turn = session.turns.sole
      Silas::AgentLoopJob.perform_now(turn.id)

      expect(turn.reload.status).to eq("completed")
      expect(turn.steps.count).to eq(1)
      expect(turn.steps.sole).to have_attributes(index: 0, terminal: true)
      expect(Silas::StepRunner).not_to have_received(:call) # framework loop bypassed
    end
  end
end
