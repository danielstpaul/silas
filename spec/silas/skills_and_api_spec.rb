require "rails_helper"

RSpec.describe "skills, instructions, and the public API" do
  include ActiveJob::TestHelper

  before { Silas::Registry.install!(root: DummyApp.root) }

  def configure_fake!(script)
    engine = FakeEngine.new(&script)
    Silas.configure do |c|
      c.engine = engine
      c.isolate_steps = false
    end
    Silas::Registry.install!(root: DummyApp.root) # configure reset the lambdas
    engine
  end

  def drain!
    20.times { break if enqueued_jobs.empty?; perform_enqueued_jobs }
  end

  describe "load_skill through the ledger" do
    it "loads a skill body as a tool result and registers it on the session" do
      script = lambda do |context|
        if context[:index].zero?
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "loading" } ],
                               tool_calls: [ EngineScripts.tool_call("t0", "load_skill", name: "summarize") ])
        else
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
        end
      end
      configure_fake!(script)

      session = Silas.agent.start(input: "summarize this")
      drain!

      turn = session.turns.sole.reload
      expect(turn.status).to eq("completed")
      inv = turn.tool_invocations.sole
      expect(inv.status).to eq("completed")
      expect(inv.result["skill"]).to eq("summarize")
      expect(inv.result["content"]).to include("Lead with the outcome.")
      expect(session.reload.loaded_skills).to eq([ "summarize" ])
    end

    it "advertises unloaded skills in the snapshot and inlines loaded ones next turn" do
      configure_fake!(EngineScripts.n_tool_steps_then_done(0))
      session = Silas::Session.create!

      turn0 = Silas::Turn.create!(session: session, index: 0, input: "hi", status: "completed")
      Silas::Instructions.snapshot!(turn0)
      expect(turn0.instructions_snapshot).to include("## Available skills")
      expect(turn0.instructions_snapshot).to include("summarize: How to write a good summary.")
      expect(turn0.instructions_snapshot).not_to include("Lead with the outcome.")

      session.update!(loaded_skills: [ "summarize" ])
      turn1 = Silas::Turn.create!(session: session, index: 1, input: "again")
      Silas::Instructions.snapshot!(turn1)
      expect(turn1.instructions_snapshot).to include("## Skill: summarize")
      expect(turn1.instructions_snapshot).to include("Lead with the outcome.")
      expect(turn1.instructions_snapshot).not_to include("## Available skills")
    end

    it "returns an error result for an unknown skill" do
      tool = Silas::Tools::LoadSkill.new
      tool.session = Silas::Session.create!
      expect(tool.call(name: "nope")).to eq({ "error" => 'unknown skill "nope"' })
    end
  end

  describe "public API" do
    it "Silas.agent.start creates a session with turn 0 enqueued" do
      configure_fake!(EngineScripts.n_tool_steps_then_done(0))
      session = Silas.agent.start(input: "hello", metadata: { "source" => "spec" })
      expect(session.turns.sole).to have_attributes(index: 0, status: "queued", input: "hello")
      drain!
      expect(session.turns.sole.reload.status).to eq("completed")
    end

    it "session.continue raises TurnInProgressError while a turn is active" do
      configure_fake!(EngineScripts.n_tool_steps_then_done(0))
      session = Silas.agent.start(input: "hello")
      expect { session.continue(input: "impatient") }.to raise_error(Silas::TurnInProgressError)
      drain!
      expect(session.continue(input: "next").index).to eq(1)
    end

    it "reads agent.yml limits through Silas.agent" do
      expect(Silas.agent.max_steps).to eq(Silas.config.max_steps) # dummy has no agent.yml
      agent = Silas::Agent.new({ "limits" => { "max_steps" => 3 }, "model" => "claude-x" })
      expect(agent.max_steps).to eq(3)
      expect(agent.model).to eq("claude-x")
    end
  end

  describe "DeadJobRescuerJob" do
    it "sweeps expired approvals before (and independently of) any queue work" do
      configure_fake!(EngineScripts.n_tool_steps_then_done(0))
      session = Silas::Session.create!
      turn = Silas::Turn.create!(session: session, index: 0, input: "hi", status: "waiting")
      step = Silas::Step.create!(turn: turn, index: 0, status: "completed")
      inv = Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "x",
                                        effect_mode: "at_most_once", approval_state: "required",
                                        approval_expires_at: 1.hour.ago)

      # Solid Queue is loaded in the harness (its internals are contract-tested)
      # but its tables are not installed here — stub the scan so this spec keeps
      # testing the approval sweep, which must happen regardless.
      relation = double("relation", find_each: nil)
      allow(SolidQueue::FailedExecution).to receive(:includes).and_return(relation)

      Silas::DeadJobRescuerJob.perform_now

      expect(inv.reload.approval_state).to eq("expired")
      expect(turn.reload.failure_reason).to eq("approval_expired")
    end
  end
end
