require "rails_helper"

# The pre-registered A1 protocol (research/a1-counterfactual-replay.md):
# day 1 is the null test — replaying a turn against its own recorded
# responses must come back byte-identical, or the probe mechanism is unsound
# and A1 stops. The divergence and gate probes build on that soundness.
RSpec.describe Silas::Replay do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund the lamp") }

  def recording_tool(approval: :never)
    tool = Object.new
    tool.define_singleton_method(:effect_mode) { :at_most_once }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**| { "ok" => true } }
    tool
  end

  def run_recorded_turn!(script, tool: recording_tool)
    Silas.configure do |c|
      c.adapter = FakeEngine.new(&script)
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
      c.tool_definitions = -> { [] }
    end
    Silas::AgentLoopJob.perform_now(turn.id)
    turn.reload
  end

  describe "the null test" do
    it "reproduces a multi-step turn byte-identically, creating nothing" do
      run_recorded_turn!(EngineScripts.n_tool_steps_then_done(2))
      expect(turn.status).to eq("completed")

      rows_before = [ Silas::Session.count, Silas::Turn.count, Silas::Step.count, Silas::ToolInvocation.count ]
      result = described_class.call(turn)

      expect(result.diverged?).to be(false)
      expect(result.probes.size).to eq(3)
      result.probes.each do |probe|
        expect(probe.verdict).to eq(:match)
        expect(probe.candidate_text).to eq(probe.recorded_text)
      end
      expect([ Silas::Session.count, Silas::Turn.count, Silas::Step.count, Silas::ToolInvocation.count ])
        .to eq(rows_before)
    end
  end

  describe "a diverging candidate" do
    it "reports the first departure with both calls, and keeps probing" do
      run_recorded_turn!(EngineScripts.n_tool_steps_then_done(2))

      candidate = FakeEngine.new do |context|
        case context[:index]
        when 0 then EngineScripts.result(blocks: [], tool_calls: [ EngineScripts.tool_call("t0_s0") ]) # same shape as recorded
        when 1 then EngineScripts.result(blocks: [], tool_calls: [ EngineScripts.tool_call("x", "shred", amount: 9) ])
        else EngineScripts.result(blocks: [ { "type" => "text", "text" => "done differently" } ])
        end
      end

      result = described_class.call(turn, candidate: candidate)

      expect(result.first_divergence.index).to eq(1)
      expect(result.first_divergence.candidate_calls).to eq([ { "name" => "shred", "arguments" => { "amount" => 9 } } ])
      expect(result.first_divergence.recorded_calls.first["name"]).to eq("record")
      expect(result.probes.size).to eq(3) # probing continues past the split
    end
  end

  describe "context fidelity" do
    it "serves the recorded history, snapshot tools, and any overrides to the candidate" do
      run_recorded_turn!(EngineScripts.n_tool_steps_then_done(1))
      turn.update!(definitions_snapshot: { "tools" => [ { "name" => "frozen" } ], "final_answer" => nil })

      candidate = FakeEngine.new { |_c| EngineScripts.result(blocks: [ { "type" => "text", "text" => "x" } ]) }
      described_class.call(turn, candidate: candidate, model: "claude-haiku-4-5", instructions: "be terse")

      first = candidate.calls.first
      expect(first[:tools]).to eq([ { "name" => "frozen" } ])
      probeed_context_model = candidate.calls.map { |c| c[:step_index] }
      expect(probeed_context_model).to eq([ 0, 1 ])
    end

    it "re-conditions every probe on the RECORDED rows, not the candidate's own outputs" do
      run_recorded_turn!(EngineScripts.n_tool_steps_then_done(1))
      original_counts = Silas.config.adapter.calls.map { |c| c[:message_count] }

      candidate = FakeEngine.new { |_c| EngineScripts.result(blocks: [ { "type" => "text", "text" => "off the rails" } ]) }
      described_class.call(turn, candidate: candidate)

      # Step 1's messages replay the recorded tool exchange — the candidate
      # sees exactly the histories the original engine saw, unaffected by its
      # own divergent step-0 answer.
      expect(candidate.calls.map { |c| c[:message_count] }).to eq(original_counts)
    end
  end

  describe "gate probing" do
    it "flags a candidate whose call would slip under an approval gate" do
      gate = ->(session:, input:) { input[:amount_pence] > 2_500 ? :user_approval : :approved }
      tool = recording_tool(approval: gate)

      script = lambda do |context|
        if context[:index].zero?
          EngineScripts.result(blocks: [],
                               tool_calls: [ EngineScripts.tool_call("t0", "record", amount_pence: 4_800) ])
        else
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "refunded" } ])
        end
      end
      run_recorded_turn!(script, tool: tool)
      turn.tool_invocations.sole.approve!(by: "dana")
      drain_jobs
      expect(turn.reload.status).to eq("completed")

      candidate = FakeEngine.new do |context|
        if context[:index].zero?
          EngineScripts.result(blocks: [],
                               tool_calls: [ EngineScripts.tool_call("c0", "record", amount_pence: 2_400) ])
        else
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "refunded" } ])
        end
      end

      probe = described_class.call(turn, candidate: candidate).probes.first
      expect(probe.verdict).to eq(:diverged)
      expect(probe.recorded_gates.values).to eq([ :would_park ])
      expect(probe.candidate_gates.values).to eq([ :auto_approved ])
      expect(probe.gate_changed?).to be(true)
    end

    it "names a hallucinated tool instead of raising" do
      run_recorded_turn!(EngineScripts.n_tool_steps_then_done(1))
      Silas.config.tool_resolver = ->(_name) { raise Silas::Error, "unknown tool" }

      candidate = FakeEngine.new do |_c|
        EngineScripts.result(blocks: [], tool_calls: [ EngineScripts.tool_call("h", "made_up_tool") ])
      end

      probe = described_class.call(turn, candidate: candidate).probes.first
      expect(probe.candidate_gates.values).to eq([ :unknown_tool ])
    end
  end

  it "honors from_step" do
    run_recorded_turn!(EngineScripts.n_tool_steps_then_done(2))
    result = described_class.call(turn, from_step: 2)
    expect(result.probes.map(&:index)).to eq([ 2 ])
  end

  def drain_jobs
    20.times { break if enqueued_jobs.empty?; perform_enqueued_jobs }
  end
end
