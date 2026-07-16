require "rails_helper"

RSpec.describe Silas::Inbox::Cost do
  let(:session) { Silas::Session.create!(agent_name: "billing") }

  def step_with_tokens(model:, input:, output:, index: 0)
    turn = Silas::Turn.create!(session: session, index: index, input: "hi")
    Silas::Step.create!(turn: turn, index: 0, status: "completed", model: model,
                        input_tokens: input, output_tokens: output)
  end

  before do
    Silas.configure { |c| c.model_prices = { "claude-sonnet-5" => { in: 300, out: 1500 } } }
  end

  it "sums step tokens and prices them per model" do
    step_with_tokens(model: "claude-sonnet-5", input: 1000, output: 2000, index: 0)
    cost = described_class.for_session(session)
    expect(cost[:input_tokens]).to eq(1000)
    expect(cost[:output_tokens]).to eq(2000)
    # (1000*300 + 2000*1500) / 1000 = 300 + 3000 = 3300 microcents
    expect(cost[:microcents]).to eq(3300)
    expect(cost[:unpriced]).to be(false)
  end

  it "flags unpriced models but still counts their tokens" do
    step_with_tokens(model: "some-unlisted-model", input: 500, output: 100, index: 0)
    cost = described_class.for_session(session)
    expect(cost[:input_tokens]).to eq(500)
    expect(cost[:unpriced]).to be(true)
    expect(cost[:microcents]).to eq(0)
  end

  it "rolls up across a whole agent" do
    step_with_tokens(model: "claude-sonnet-5", input: 100, output: 200, index: 0)
    other = Silas::Session.create!(agent_name: "billing")
    t = Silas::Turn.create!(session: other, index: 0, input: "x")
    Silas::Step.create!(turn: t, index: 0, status: "completed", model: "claude-sonnet-5",
                        input_tokens: 100, output_tokens: 200)
    expect(described_class.for_agent("billing")[:input_tokens]).to eq(200)
  end

  it "formats microcents as dollars" do
    expect(described_class.format(3300)).to eq("$0.0033")
    expect(described_class.format(nil)).to be_nil
  end
end
