require "rails_helper"

RSpec.describe Silas::AgentSdk::StreamParser do
  subject(:parser) { described_class.new }

  def feed(lines)
    events = []
    lines.each { |l| parser.ingest(l) { |e| events << e } }
    events
  end

  let(:stream) do
    [
      %({"type":"system","subtype":"init","session_id":"sess-abc","model":"claude-haiku"}),
      %({"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"echo_note","input":{"text":"hi"}}]}}),
      %({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1"}]}}),
      %({"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}),
      %({"type":"result","subtype":"success","result":"done","total_cost_usd":0.002,"usage":{"input_tokens":9,"output_tokens":4}}),
    ]
  end

  it "extracts session_id from the init event" do
    feed(stream)
    expect(parser.session_id).to eq("sess-abc")
  end

  it "emits typed events for each line" do
    types = feed(stream).map(&:type)
    expect(types).to include(:"system.init", :tool_call, :tool_result, :text, :result)
  end

  it "builds a Result with final text, no tool_calls, and usage" do
    feed(stream)
    result = parser.to_result
    expect(result.tool_calls).to eq([]) # engine already executed the tools
    expect(result.stop_reason).to eq("success")
    expect(result.blocks).to include({ "type" => "text", "text" => "done" })
    expect(result.usage[:input_tokens]).to eq(9)
    expect(result.usage[:cost_usd]).to eq(0.002)
  end

  it "is tolerant of blank and non-JSON lines" do
    expect {
      parser.ingest("") {}
      parser.ingest("Warning: something\n") {}
      parser.ingest("not json at all") {}
    }.not_to raise_error
  end

  it "does not raise on an unknown event type" do
    events = feed([ %({"type":"brand_new_event_kind","foo":1}) ])
    expect(events.map(&:type)).to eq([ :unknown ])
  end
end
