require "rails_helper"

# Hermetic: we don't load turbo-rails (that would contaminate the whole suite
# with live broadcasts). Instead we force streaming? on and stub the single
# turbo seam (silas_inbox_dispatch) to assert the DISPATCH logic — which event
# broadcasts which target — and that a broadcast failure never breaks a turn.
RSpec.describe Silas::Inbox::Broadcastable do
  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi") }

  before { allow(Silas::Inbox).to receive(:streaming?).and_return(true) }

  def captured_dispatches
    calls = []
    allow_any_instance_of(described_class).to receive(:silas_inbox_dispatch) do |_obj, action, sid, **opts|
      calls << { action: action, session_id: sid, target: opts[:target] }
    end
    calls
  end

  it "appends a turn to #silas-turns on create" do
    calls = captured_dispatches
    Silas::Turn.create!(session: session, index: 1, input: "x")
    expect(calls).to include(a_hash_including(action: :append, target: "silas-turns"))
  end

  it "appends a step to its turn's step container on create" do
    calls = captured_dispatches
    Silas::Step.create!(turn: turn, index: 0)
    expect(calls).to include(a_hash_including(action: :append, target: "silas-turn-#{turn.id}-steps"))
  end

  it "replaces the turn header when status changes" do
    calls = captured_dispatches
    turn.update!(status: "running")
    expect(calls).to include(a_hash_including(action: :replace, target: "silas-turn-#{turn.id}-header"))
  end

  it "replaces the invocation and does not fire on an unrelated update" do
    step = Silas::Step.create!(turn: turn, index: 0)
    inv = Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0",
                                        tool_name: "x", effect_mode: "at_most_once")
    calls = captured_dispatches
    inv.update!(approval_state: "required")
    expect(calls).to include(a_hash_including(action: :replace, target: dom_id(inv)))
  end

  it "does not broadcast when streaming is off" do
    allow(Silas::Inbox).to receive(:streaming?).and_return(false)
    calls = captured_dispatches
    Silas::Turn.create!(session: session, index: 2, input: "x")
    expect(calls).to be_empty
  end

  it "swallows a broadcast failure — the row still commits" do
    allow_any_instance_of(described_class).to receive(:silas_inbox_dispatch).and_raise("cable down")
    created = nil
    expect { created = Silas::Turn.create!(session: session, index: 3, input: "x") }.not_to raise_error
    expect(created.reload).to be_persisted
  end

  private

  def dom_id(record) = ActionView::RecordIdentifier.dom_id(record)
end
