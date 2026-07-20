require "rails_helper"

RSpec.describe "approvals end-to-end" do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund order 42") }

  def recording_tool(approval:)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { :at_most_once }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true } }
    tool
  end

  def configure!(engine, tool)
    Silas.configure do |c|
      c.engine = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
    end
  end

  def drain!
    20.times { break if enqueued_jobs.empty?; perform_enqueued_jobs }
  end

  it "park → approve! → fresh job completes with exactly-once execution" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool(approval: :always)
    configure!(engine, tool)

    Silas::AgentLoopJob.perform_now(turn.id)
    inv = turn.reload.tool_invocations.sole
    expect(turn.status).to eq("waiting")

    inv.approve!(by: "daniel")
    drain!

    turn.reload
    expect(turn.status).to eq("completed")
    expect(tool.executions.size).to eq(1)
    expect(inv.reload).to have_attributes(status: "completed", approval_state: "approved", approved_by: "daniel")
    expect(engine.calls.map { |c| c[:step_index] }).to eq([ 0, 1 ]) # step 0 replayed from rows
  end

  it "park → decline! → the model sees {denied:} and the loop continues" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool(approval: :always)
    configure!(engine, tool)

    Silas::AgentLoopJob.perform_now(turn.id)
    inv = turn.reload.tool_invocations.sole

    inv.decline!(reason: "amount too large", by: "daniel")
    drain!

    turn.reload
    expect(turn.status).to eq("completed")
    expect(tool.executions).to be_empty
    expect(inv.reload).to have_attributes(status: "failed", approval_state: "declined")

    # The denial rode the transcript into the next model call.
    final_call = engine.calls.last
    expect(final_call[:roles]).to eq(%w[user assistant tool])
    messages = Silas::MessageBuilder.call(turn, upto_index: 1)
    expect(messages.last[:content]).to eq({ "denied" => "amount too large" })
  end

  it "in-doubt → approve! re-executes exactly once" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool(approval: :never)
    configure!(engine, tool)

    # Manufacture the in-doubt window: crash after claim, before completion.
    Silas::Instructions.snapshot!(turn)
    Silas::StepRunner.call(turn, 0) rescue nil
    inv = turn.reload.tool_invocations.sole
    inv.update!(status: "started") # as if we died mid-external-call
    tool.executions.clear

    Silas::AgentLoopJob.perform_now(turn.id)
    expect(turn.reload.status).to eq("in_doubt")
    expect(inv.reload.status).to eq("in_doubt")

    inv.approve!(by: "daniel")
    drain!

    expect(turn.reload.status).to eq("completed")
    expect(tool.executions.size).to eq(1)
    expect(inv.reload.status).to eq("completed")
  end

  it "in-doubt → decline! records the operator verdict and the turn continues" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool(approval: :never)
    configure!(engine, tool)

    Silas::Instructions.snapshot!(turn)
    Silas::StepRunner.call(turn, 0) rescue nil
    inv = turn.reload.tool_invocations.sole
    inv.update!(status: "started")
    tool.executions.clear

    Silas::AgentLoopJob.perform_now(turn.id)
    inv.reload.decline!(reason: "it already ran", by: "daniel")
    drain!

    expect(turn.reload.status).to eq("completed")
    expect(tool.executions).to be_empty
    expect(inv.reload).to have_attributes(status: "failed", approval_state: "declined",
                                          decline_reason: "it already ran")
  end

  it "expire_stale! fails past-TTL parked invocations and their turns" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool(approval: :always)
    configure!(engine, tool)

    Silas::AgentLoopJob.perform_now(turn.id)
    inv = turn.reload.tool_invocations.sole
    inv.update!(approval_expires_at: 1.hour.ago)

    Silas::ToolInvocation.expire_stale!

    expect(inv.reload).to have_attributes(status: "failed", approval_state: "expired")
    expect(turn.reload).to have_attributes(status: "failed", failure_reason: "approval_expired")
  end

  it "approval lambdas see indifferent-access input (jsonb string keys, symbol lookups work)" do
    seen = nil
    policy = lambda do |session:, input:|
      seen = input
      input[:amount].to_i > 50 ? :user_approval : :approved
    end
    engine = FakeEngine.new do |context|
      if context[:index].zero?
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "gating" } ],
                             tool_calls: [ EngineScripts.tool_call("t0", amount: 100) ])
      else
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
      end
    end
    tool = recording_tool(approval: policy)
    configure!(engine, tool)

    Silas::AgentLoopJob.perform_now(turn.id)

    expect(seen[:amount]).to eq(100)   # symbol lookup on jsonb-stored args
    expect(seen["amount"]).to eq(100)  # string lookup still works
    expect(turn.reload.status).to eq("waiting") # 100 > 50 parked
  end

  it "approve! refuses an invocation that is not parked" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(0))
    tool = recording_tool(approval: :never)
    configure!(engine, tool)
    Silas::AgentLoopJob.perform_now(turn.id)

    step = turn.reload.steps.first
    inv = Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "manual", tool_name: "x",
                                      effect_mode: "at_most_once", status: "completed")
    expect { inv.approve! }.to raise_error(Silas::Error, /not awaiting approval/)
  end
end
