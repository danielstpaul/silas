require "rails_helper"

RSpec.describe Silas::Inbox::Cost do
  let(:session) { Silas::Session.create!(agent_name: "billing") }

  def step_with_tokens(model:, input:, output:, index: 0, provider: nil)
    turn = Silas::Turn.create!(session: session, index: index, input: "hi")
    Silas::Step.create!(turn: turn, index: 0, status: "completed", model: model,
                        provider: provider, input_tokens: input, output_tokens: output)
  end

  it "prices registry models from RubyLLM (no hand-maintained map needed)" do
    # claude-sonnet-4-5: $3/$15 per MTok in the shipped registry -> 3000/15000 units per 1k.
    step_with_tokens(model: "claude-sonnet-4-5", provider: "anthropic", input: 1000, output: 2000)
    cost = described_class.for_session(session)
    expect(cost[:input_tokens]).to eq(1000)
    expect(cost[:output_tokens]).to eq(2000)
    # (1000*3000 + 2000*15000) / 1000 = 3000 + 30000 = 33000 microcents ($0.033)
    expect(cost[:microcents]).to eq(33_000)
    expect(cost[:unpriced]).to be(false)
  end

  it "lets config.model_prices OVERRIDE the registry" do
    Silas.configure { |c| c.model_prices = { "claude-sonnet-4-5" => { in: 300, out: 1500 } } }
    step_with_tokens(model: "claude-sonnet-4-5", provider: "anthropic", input: 1000, output: 2000)
    # Override rates, not the registry's: (1000*300 + 2000*1500) / 1000 = 3300.
    expect(described_class.for_session(session)[:microcents]).to eq(3300)
  end

  it "prices custom models purely from the override map" do
    Silas.configure { |c| c.model_prices = { "my-fine-tune" => { in: 300, out: 1500 } } }
    step_with_tokens(model: "my-fine-tune", input: 1000, output: 2000)
    cost = described_class.for_session(session)
    expect(cost[:microcents]).to eq(3300)
    expect(cost[:unpriced]).to be(false)
  end

  it "flags unpriced models but still counts their tokens — unknown is never $0.00" do
    step_with_tokens(model: "some-unlisted-model", input: 500, output: 100)
    cost = described_class.for_session(session)
    expect(cost[:input_tokens]).to eq(500)
    expect(cost[:unpriced]).to be(true)
    expect(cost[:microcents]).to eq(0)
  end

  it "uses the two-arg registry lookup when the step stamped a provider" do
    # 85/1081 registry ids exist under multiple providers at different prices —
    # the bare lookup tie-breaks by a hardcoded preference and can price wrong.
    expect(::RubyLLM.models).to receive(:find).with("claude-sonnet-4-5", "anthropic").and_call_original
    step_with_tokens(model: "claude-sonnet-4-5", provider: "anthropic", input: 10, output: 10)
    described_class.for_session(session)
  end

  it "rolls up across a whole agent" do
    step_with_tokens(model: "claude-sonnet-4-5", provider: "anthropic", input: 100, output: 200)
    other = Silas::Session.create!(agent_name: "billing")
    t = Silas::Turn.create!(session: other, index: 0, input: "x")
    Silas::Step.create!(turn: t, index: 0, status: "completed", model: "claude-sonnet-4-5",
                        provider: "anthropic", input_tokens: 100, output_tokens: 200)
    expect(described_class.for_agent("billing")[:input_tokens]).to eq(200)
  end

  it "formats microcents as dollars" do
    expect(described_class.format(3300)).to eq("$0.0033")
    expect(described_class.format(nil)).to be_nil
  end

  describe "provider stamping (StepRunner)" do
    it "stamps the provider RubyLLM resolves for the turn's model" do
      engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(0))
      Silas.configure do |c|
        c.adapter = engine
        c.isolate_steps = false
        c.tool_resolver = ->(_n) { raise "no tools" }
      end
      turn = Silas::Turn.create!(session: session, index: 0, input: "hi",
                                 status: "running", instructions_snapshot: "sys")

      Silas::StepRunner.call(turn, 0)

      # default_model claude-sonnet-4-5 -> anthropic in the shipped registry
      expect(turn.steps.sole.provider).to eq("anthropic")
    end
  end
end
