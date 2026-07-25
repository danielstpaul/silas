require "rails_helper"

# The token-streaming seam: engine Events -> DeltaBuffer -> "silas.delta"
# notifications. Deltas are decoration over the authoritative rows — never
# persisted, never re-emitted on replay.
RSpec.describe "token streaming" do
  # An engine that streams two text deltas before answering.
  class StreamingEngine < Silas::Adapters::Base
    def execute_step(_context, &on_event)
      on_event&.call(Silas::Event.new(type: :message_start, payload: {}))
      on_event&.call(Silas::Event.new(type: :text_delta, payload: { text: "Hel" }))
      on_event&.call(Silas::Event.new(type: :text_delta, payload: { text: "lo!" }))
      Silas::Adapters::Result.new(blocks: [ { "type" => "text", "text" => "Hello!" } ],
                                 tool_calls: [], stop_reason: "end_turn",
                                 usage: { input_tokens: 1, output_tokens: 1 })
    end
  end

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi", status: "running", instructions_snapshot: "sys") }

  def configure!(engine = StreamingEngine.new)
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { raise "no tools in this spec" }
    end
  end

  def capture_deltas
    events = []
    subscription = ActiveSupport::Notifications.subscribe("silas.delta") { |*args| events << args.last }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  it "publishes coalesced, accumulated text with full addressing ids" do
    configure!
    events = capture_deltas { Silas::StepRunner.call(turn, 0) }

    # First append always publishes; the second lands within INTERVAL and is
    # coalesced; finish flushes the accumulated tail.
    expect(events.map { |e| e[:text] }).to eq([ "Hel", "Hello!" ])
    step = turn.steps.sole
    expect(events.last).to include(session_id: session.id, turn_id: turn.id,
                                   step_id: step.id, step_index: 0)
    expect(step.reload).to have_attributes(status: "completed", terminal: true)
  end

  it "emits nothing when a completed step is replayed (durability rule)" do
    configure!
    Silas::StepRunner.call(turn, 0)

    replay_events = capture_deltas { Silas::StepRunner.call(turn, 0) }
    expect(replay_events).to be_empty
  end

  it "streams through an around_model_call hook without the hook seeing or swallowing the block" do
    seen_context = nil
    Silas.configure do |c|
      c.adapter = StreamingEngine.new
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { raise "no tools in this spec" }
      c.around_model_call = ->(ctx, &call) { seen_context = ctx; call.call }
    end

    events = capture_deltas { Silas::StepRunner.call(turn, 0) }
    expect(events.map { |e| e[:text] }).to eq([ "Hel", "Hello!" ])
    expect(seen_context).to include(index: 0)
  end

  it "flushes the tail even when the engine raises mid-stream" do
    exploding = Class.new(Silas::Adapters::Base) do
      def execute_step(_context, &on_event)
        on_event&.call(Silas::Event.new(type: :text_delta, payload: { text: "par" }))
        on_event&.call(Silas::Event.new(type: :text_delta, payload: { text: "tial" }))
        raise "provider fell over"
      end
    end.new
    configure!(exploding)

    events = capture_deltas do
      expect { Silas::StepRunner.call(turn, 0) }.to raise_error("provider fell over")
    end
    expect(events.last[:text]).to eq("partial") # ensure-path flush
  end

  describe Silas::DeltaBuffer do
    it "coalesces appends inside the interval and never re-publishes unchanged text" do
      step = Silas::Step.create!(turn: turn, index: 0)
      buffer = described_class.new(turn: turn, step: step)

      events = capture_deltas do
        buffer.append("a")   # publishes (first)
        buffer.append("b")   # coalesced
        buffer.finish        # flushes "ab"
        buffer.finish        # no-op: nothing new
      end
      expect(events.map { |e| e[:text] }).to eq([ "a", "ab" ])
    end
  end
end
