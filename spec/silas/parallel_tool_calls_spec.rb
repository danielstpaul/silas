require "rails_helper"

# The model may emit several tool_use blocks in ONE assistant turn (parallel
# tool calls). The ledger must settle every invocation, the turn must reach a
# terminal state, and MessageBuilder must replay a transcript where each
# tool_result has a matching tool_use in the preceding assistant message.
RSpec.describe "parallel tool calls" do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "look it up") }

  def recording_tool(effect_mode: :at_most_once, approval: :never)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { effect_mode }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true } }
    tool
  end

  # Step 0: two parallel calls to the same tool. Step 1: terminal text.
  def two_parallel_then_done
    lambda do |context|
      if context[:index].zero?
        EngineScripts.result(
          blocks: [ { "type" => "text", "text" => "looking" } ],
          tool_calls: [ EngineScripts.tool_call("call_a", "lookup", order_id: 1),
                        EngineScripts.tool_call("call_b", "lookup", order_id: 1) ]
        )
      else
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
      end
    end
  end

  it "settles both invocations and completes the turn" do
    engine = FakeEngine.new(&two_parallel_then_done)
    tool = recording_tool
    Silas.configure do |c|
      c.engine = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
    end

    Silas::AgentLoopJob.perform_now(turn.id)

    turn.reload
    expect(turn.tool_invocations.count).to eq(2)
    expect(turn.tool_invocations.map(&:status).uniq).to eq(%w[completed])
    expect(tool.executions.size).to eq(2)
    expect(turn.status).to eq("completed")
  end

  it "runs an ungated invocation and parks a gated sibling in the same step" do
    # Gated call is ordered FIRST — the old settle! bailed on it and left the
    # ungated sibling stranded. Both must be handled: ungated runs, gated parks.
    engine = FakeEngine.new do |context|
      if context[:index].zero?
        EngineScripts.result(
          blocks: [ { "type" => "text", "text" => "acting" } ],
          tool_calls: [ EngineScripts.tool_call("g", "gated", x: 1),
                        EngineScripts.tool_call("u", "ungated", y: 2) ]
        )
      else
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
      end
    end
    gated = recording_tool(approval: :always)
    ungated = recording_tool(approval: :never)
    tools = { "gated" => gated, "ungated" => ungated }
    Silas.configure do |c|
      c.engine = engine
      c.isolate_steps = false
      c.tool_resolver = ->(name) { tools.fetch(name) }
    end

    Silas::AgentLoopJob.perform_now(turn.id)

    turn.reload
    expect(turn.status).to eq("waiting")
    expect(ungated.executions.size).to eq(1)            # ran despite the gated sibling parking
    gated_inv = turn.tool_invocations.find_by(tool_name: "gated")
    expect(gated_inv.approval_state).to eq("required")
    expect(gated.executions).to be_empty

    gated_inv.update!(approval_state: "approved")
    turn.update!(status: "queued")
    Silas::AgentLoopJob.perform_now(turn.id)

    expect(turn.reload.status).to eq("completed")
    expect(gated.executions.size).to eq(1)              # executed once, after approval
    expect(ungated.executions.size).to eq(1)            # not re-run on resume
  end

  it "replays a transcript where every tool_result has a matching tool_use" do
    engine = FakeEngine.new(&two_parallel_then_done)
    tool = recording_tool
    Silas.configure do |c|
      c.engine = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
    end
    Silas::AgentLoopJob.perform_now(turn.id)

    messages = Silas::MessageBuilder.call(turn.reload, upto_index: nil)
    assistant = messages.find { |m| m[:role] == "assistant" }
    tool_use_ids = assistant[:content].select { |b| b["type"] == "tool_call" }.map { |b| b["id"] }
    tool_result_ids = messages.select { |m| m[:role] == "tool" }.map { |m| m[:tool_call_id] }

    expect(tool_use_ids).to match_array(%w[call_a call_b])
    expect(tool_result_ids).to match_array(tool_use_ids)
  end
end
