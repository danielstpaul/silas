require "rails_helper"

RSpec.describe "schema invariants" do
  let(:session) { Silas::Session.create! }

  it "boots and migrates all four tables" do
    expect(ActiveRecord::Base.connection.tables).to include(
      "silas_sessions", "silas_turns", "silas_steps", "silas_tool_invocations"
    )
  end

  it "enforces one turn per (session, index)" do
    Silas::Turn.create!(session: session, index: 0, input: "hi", status: "completed")
    expect {
      Silas::Turn.create!(session: session, index: 0, input: "again", status: "completed")
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "enforces the single-active-turn invariant at the database level" do
    Silas::Turn.create!(session: session, index: 0, input: "hi", status: "running")
    expect {
      Silas::Turn.create!(session: session, index: 1, input: "concurrent", status: "queued")
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a new turn once the previous one is final" do
    Silas::Turn.create!(session: session, index: 0, input: "hi", status: "completed")
    expect {
      Silas::Turn.create!(session: session, index: 1, input: "next", status: "queued")
    }.not_to raise_error
  end

  it "enforces at most one persisted model response per (turn, index)" do
    turn = Silas::Turn.create!(session: session, index: 0, input: "hi")
    Silas::Step.create!(turn: turn, index: 0)
    expect {
      Silas::Step.create!(turn: turn, index: 0)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "enforces the exactly-once ledger key (step_id, tool_call_id)" do
    turn = Silas::Turn.create!(session: session, index: 0, input: "hi")
    step = Silas::Step.create!(turn: turn, index: 0)
    common = { step: step, turn: turn, tool_call_id: "t0", tool_name: "x", effect_mode: "at_most_once" }
    Silas::ToolInvocation.create!(**common)
    expect {
      Silas::ToolInvocation.create!(**common)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "makes step.terminal write-once" do
    turn = Silas::Turn.create!(session: session, index: 0, input: "hi")
    step = Silas::Step.create!(turn: turn, index: 0)
    step.update!(terminal: false)
    expect { step.update!(terminal: true) }.to raise_error(ActiveRecord::RecordInvalid, /write-once/)
  end

  it "makes turn.instructions_snapshot immutable once set" do
    turn = Silas::Turn.create!(session: session, index: 0, input: "hi")
    turn.update!(instructions_snapshot: "You are Silas.")
    expect {
      turn.update!(instructions_snapshot: "You are someone else.")
    }.to raise_error(ActiveRecord::RecordInvalid, /immutable/)
  end
end
