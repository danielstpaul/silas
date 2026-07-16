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

  describe "enforced in the loop" do
    it "fails the turn with the budget reason instead of running forever" do
      # Engine that always wants another tool call (would loop to max_steps).
      engine = FakeEngine.new do |context|
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "more" } ],
                             tool_calls: [ EngineScripts.tool_call("t#{context[:index]}") ]).tap do |r|
          r.usage[:input_tokens] = 5_000
        end
      end
      tool = Object.new
      tool.define_singleton_method(:effect_mode) { :transactional }
      tool.define_singleton_method(:approval_policy) { :never }
      tool.define_singleton_method(:call) { |**| { "ok" => true } }

      # agent.yml with a token cap; needs Silas.agent to see it -> stub the agent.
      allow(Silas).to receive(:agent).and_return(Silas::Agent.new("limits" => { "max_input_tokens" => 8_000, "max_steps" => 25 }))
      Silas.configure do |c|
        c.engine = engine
        c.isolate_steps = false
        c.tool_resolver = ->(_n) { tool }
      end

      t = Silas::Turn.create!(session: session, index: 1, input: "loop")
      Silas::AgentLoopJob.perform_now(t.id)

      expect(t.reload.status).to eq("failed")
      expect(t.failure_reason).to eq("max_input_tokens")
      expect(t.steps.count).to be < 25 # stopped early, didn't burn to max_steps
    end
  end
end
