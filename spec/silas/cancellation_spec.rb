require "rails_helper"

# Turn cancellation: parked/queued turns settle to canceled immediately (with
# pending approvals expired so approve! can't zombie-resume them); running
# turns are flagged and honored at the next step boundary — the same safe
# point budgets use.
RSpec.describe "turn cancellation" do
  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "do the thing") }

  def recording_tool(approval: :never)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { :transactional }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true } }
    tool
  end

  def configure!(engine, tool)
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
    end
  end

  it "cancels a parked turn immediately and expires its approvals" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    tool = recording_tool(approval: :always)
    configure!(engine, tool)
    Silas::AgentLoopJob.perform_now(turn.id)
    expect(turn.reload.status).to eq("waiting")

    expect(turn.cancel!).to eq(:canceled)

    turn.reload
    expect(turn.status).to eq("canceled")
    expect(turn.finished_at).to be_present
    invocation = turn.tool_invocations.sole
    expect(invocation.approval_state).to eq("expired")
    expect(invocation.status).to eq("failed")

    # approve! on the expired invocation must not resurrect the turn
    expect { invocation.approve!(by: "late") }.to raise_error(Silas::Error)
    expect(tool.executions).to be_empty
  end

  it "honors a mid-run cancel at the next step boundary" do
    # Engine that would run 5 steps; we flag cancellation from inside step 1's
    # tool call, so the loop should stop before step 2's model call.
    the_turn = turn
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(5))
    tool = Object.new
    tool.define_singleton_method(:effect_mode) { :transactional }
    tool.define_singleton_method(:approval_policy) { :never }
    tool.define_singleton_method(:call) do |**|
      the_turn.update!(cancel_requested_at: Time.current) # cancel arrives mid-run
      { "ok" => true }
    end
    configure!(engine, tool)

    Silas::AgentLoopJob.perform_now(turn.id)

    turn.reload
    expect(turn.status).to eq("canceled")
    expect(turn.failure_reason).to eq("canceled")
    expect(engine.calls.size).to eq(1)             # step 0 only — no further model calls
    expect(turn.steps.where(status: "completed").count).to eq(1) # step 0's work is kept
  end

  it "cancel! on a running turn flags rather than settles" do
    turn.update!(status: "running", started_at: Time.current)
    expect(turn.cancel!).to eq(:cancel_requested)
    expect(turn.reload.status).to eq("running")    # loop settles it at the boundary
    expect(turn.cancel_requested_at).to be_present
  end

  it "refuses to cancel a terminal turn" do
    turn.update!(status: "completed")
    expect { turn.cancel! }.to raise_error(Silas::Error, /already terminal/)
  end
end
