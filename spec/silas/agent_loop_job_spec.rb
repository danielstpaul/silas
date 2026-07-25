require "rails_helper"

RSpec.describe Silas::AgentLoopJob do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "do the thing") }

  # A tool with an observable side effect (nonce rows in loaded_skills would be
  # gross — use a plain array recorder).
  def recording_tool(effect_mode: :transactional, approval: :never)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { effect_mode }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true } }
    tool
  end

  def configure!(engine, tool)
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false # inline logic specs; isolation covered separately
      c.tool_resolver = ->(_name) { tool }
    end
  end

  it "runs a multi-step turn to completion with exactly-once tool effects" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(2))
    tool = recording_tool
    configure!(engine, tool)

    described_class.perform_now(turn.id)

    turn.reload
    expect(turn.status).to eq("completed")
    expect(turn.finished_at).to be_present
    expect(turn.steps.count).to eq(3)
    expect(turn.steps.map(&:terminal)).to eq([ false, false, true ])
    expect(tool.executions).to eq([ {}, {} ])
    expect(turn.instructions_snapshot).to be_present
    expect(engine.calls.size).to eq(3)

    # Regression: each step must SEE the accumulated history (a cached-empty
    # turn.steps association once erased the model's own tool results).
    expect(engine.calls.map { |c| c[:roles] }).to eq([
      %w[user],
      %w[user assistant tool],
      %w[user assistant tool assistant tool]
    ])
  end

  it "is replay-safe: re-running a completed turn calls no model and re-runs no tools" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(2))
    tool = recording_tool
    configure!(engine, tool)

    described_class.perform_now(turn.id)
    described_class.perform_now(turn.id)

    expect(engine.calls.size).to eq(3)
    expect(tool.executions.size).to eq(2)
  end

  it "replays completed steps from rows when a turn is re-run mid-flight" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(2))
    tool = recording_tool
    configure!(engine, tool)

    # Simulate a crash after step 0 committed: run only step 0's work.
    Silas::Instructions.snapshot!(turn)
    Silas::StepRunner.call(turn, 0)
    expect(engine.calls.size).to eq(1)

    # The re-run (fresh job, as after a rescue) must not repeat step 0's
    # model call or tool effect.
    described_class.perform_now(turn.id)

    expect(turn.reload.status).to eq("completed")
    expect(engine.calls.map { |c| c[:step_index] }).to eq([ 0, 1, 2 ])
    expect(tool.executions.size).to eq(2)
  end

  it "parks the turn when an approval fires, and a fresh job resumes after approval" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool(approval: :always)
    configure!(engine, tool)

    described_class.perform_now(turn.id)

    turn.reload
    expect(turn.status).to eq("waiting")
    inv = turn.tool_invocations.sole
    expect(inv.approval_state).to eq("required")
    expect(tool.executions).to be_empty
    expect(engine.calls.size).to eq(1) # parked at zero compute after step 0

    # Approve (the D7 approve! flow, done by hand here) and resume fresh.
    inv.update!(approval_state: "approved")
    turn.update!(status: "queued")
    described_class.perform_now(turn.id)

    expect(turn.reload.status).to eq("completed")
    expect(tool.executions.size).to eq(1)         # executed exactly once
    expect(engine.calls.map { |c| c[:step_index] }).to eq([ 0, 1 ]) # step 0 NOT re-called
  end

  it "fails the turn with limit_exceeded when max_steps is hit" do
    engine = FakeEngine.new do |context|
      EngineScripts.result(blocks: [ { "type" => "text", "text" => "more" } ],
                           tool_calls: [ EngineScripts.tool_call("t#{context[:index]}") ])
    end
    tool = recording_tool
    configure!(engine, tool)
    Silas.config.max_steps = 3

    described_class.perform_now(turn.id)

    turn.reload
    expect(turn.status).to eq("failed")
    expect(turn.failure_reason).to eq("max_steps")
    expect(engine.calls.size).to eq(3)
  end

  it "reconstructs the conversation deterministically via MessageBuilder" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool
    configure!(engine, tool)
    described_class.perform_now(turn.id)

    messages = Silas::MessageBuilder.call(turn.reload, upto_index: nil)
    expect(messages.first).to eq({ role: "user", content: "do the thing" })
    roles = messages.map { |m| m[:role] }
    expect(roles).to eq(%w[user assistant tool assistant])
    expect(Silas::MessageBuilder.call(turn, upto_index: nil)).to eq(messages) # byte-stable
  end

  describe "with isolated steps (the production configuration)" do
    it "re-enqueues between steps and completes across executions" do
      engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(2))
      tool = recording_tool
      configure!(engine, tool)
      Silas.config.isolate_steps = true

      described_class.perform_later(turn.id)

      executions = 0
      while enqueued_jobs.any? && executions < 20
        executions += 1
        perform_enqueued_jobs
      end

      expect(turn.reload.status).to eq("completed")
      expect(executions).to be > 1 # the continuation actually interrupted + resumed
      expect(tool.executions.size).to eq(2)
      expect(engine.calls.size).to eq(3)
    end
  end
end
