require "rails_helper"

RSpec.describe Silas::Budget do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi", status: "running", started_at: Time.current) }

  def agent(limits) = Silas::Agent.new("limits" => limits)

  def step!(input:, output: 0, model: "claude-sonnet-5")
    idx = turn.steps.count
    Silas::Step.create!(turn: turn, index: idx, status: "completed", model: model,
                        input_tokens: input, output_tokens: output)
  end

  before { Silas.configure { |c| c.model_prices = { "claude-sonnet-5" => { in: 300, out: 1500 } } } }

  it "returns nil when no limits are set" do
    step!(input: 10_000)
    expect(described_class.exceeded_reason(turn, agent: agent({}))).to be_nil
  end

  it "flags max_input_tokens once cumulative input exceeds the cap" do
    step!(input: 600); step!(input: 600)
    expect(described_class.exceeded_reason(turn, agent: agent("max_input_tokens" => 1000))).to eq("max_input_tokens")
    expect(described_class.exceeded_reason(turn, agent: agent("max_input_tokens" => 2000))).to be_nil
  end

  it "flags max_cost in dollars from priced tokens" do
    # (10_000*300 + 2_000*1500)/1000 = 6_000 cost-units; 1e6 units = $1 -> $0.006
    step!(input: 10_000, output: 2_000)
    expect(described_class.exceeded_reason(turn, agent: agent("max_cost" => 0.005))).to eq("max_cost")
    expect(described_class.exceeded_reason(turn, agent: agent("max_cost" => 0.007))).to be_nil
  end

  it "flags timeout on wall-clock" do
    turn.update!(started_at: 10.minutes.ago)
    expect(described_class.exceeded_reason(turn, agent: agent("timeout" => 60))).to eq("timeout")
    expect(described_class.exceeded_reason(turn, agent: agent("timeout" => 3600))).to be_nil
  end

  it "consults a per-turn override ahead of the agent's limit" do
    step!(input: 600); step!(input: 600)
    limited = agent("max_input_tokens" => 1000)
    expect(described_class.exceeded_reason(turn, agent: limited)).to eq("max_input_tokens")

    turn.update!(budget_overrides: { "max_input_tokens" => 5000 })
    expect(described_class.exceeded_reason(turn, agent: limited)).to be_nil
  end

  describe "enforced in the loop" do
    # Engine that always wants another tool call (would loop to max_steps).
    def hungry_engine
      FakeEngine.new do |context|
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "more" } ],
                             tool_calls: [ EngineScripts.tool_call("t#{context[:index]}") ]).tap do |r|
          r.usage[:input_tokens] = 5_000
        end
      end
    end

    def recording_tool
      tool = Object.new
      tool.define_singleton_method(:effect_mode) { :transactional }
      tool.define_singleton_method(:approval_policy) { :never }
      tool.define_singleton_method(:call) { |**| { "ok" => true } }
      tool
    end

    it "PARKS the turn with the budget reason instead of running forever" do
      engine = hungry_engine
      # agent.yml with a token cap; needs Silas.agent to see it -> stub the agent.
      allow(Silas).to receive(:agent).and_return(Silas::Agent.new("limits" => { "max_input_tokens" => 8_000, "max_steps" => 25 }))
      Silas.configure do |c|
        c.engine = engine
        c.isolate_steps = false
        c.tool_resolver = ->(_n) { recording_tool }
      end

      t = Silas::Turn.create!(session: session, index: 1, input: "loop")
      Silas::AgentLoopJob.perform_now(t.id)

      t.reload
      expect(t.status).to eq("waiting")             # parked, not failed
      expect(t.failure_reason).to eq("max_input_tokens")
      expect(t.budget_parked?).to be(true)
      expect(t.steps.count).to be < 25              # stopped early
      expect(t.finished_at).to be_nil               # not terminal
    end

    it "raise_budget! resumes from the park without re-running completed steps" do
      # Terminal after 3 steps, but the cap trips after 2 (2 x 5000 > 8000).
      engine = FakeEngine.new do |context|
        if context[:index] < 3
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "s#{context[:index]}" } ],
                               tool_calls: [ EngineScripts.tool_call("t#{context[:index]}") ]).tap do |r|
            r.usage[:input_tokens] = 5_000
          end
        else
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
        end
      end
      allow(Silas).to receive(:agent).and_return(Silas::Agent.new("limits" => { "max_input_tokens" => 8_000, "max_steps" => 25 }))
      Silas.configure do |c|
        c.engine = engine
        c.isolate_steps = false
        c.tool_resolver = ->(_n) { recording_tool }
      end

      previous = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :inline
      begin
        t = Silas::Turn.create!(session: session, index: 1, input: "big job")
        Silas::AgentLoopJob.perform_now(t.id)
        expect(t.reload.budget_parked?).to be(true)
        calls_at_park = engine.calls.size

        t.raise_budget!(max_input_tokens: 100_000)   # human tops up -> resumes inline

        t.reload
        expect(t.status).to eq("completed")
        expect(t.failure_reason).to be_nil
        # Completed steps replayed from rows: only the REMAINING steps hit the engine.
        expect(engine.calls.size).to be > calls_at_park
        expect(engine.calls.map { |c| c[:step_index] }.uniq).to eq(engine.calls.map { |c| c[:step_index] })
      ensure
        ActiveJob::Base.queue_adapter = previous
      end
    end

    it "raise_budget! refuses turns that are not budget-parked" do
      t = Silas::Turn.create!(session: session, index: 1, input: "hi", status: "running")
      expect { t.raise_budget!(max_cost: 1.0) }.to raise_error(Silas::Error, /not budget-parked/)
    end
  end
end
