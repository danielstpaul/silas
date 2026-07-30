require "rails_helper"

# A park must survive `git push`. The turn snapshots everything the model can
# see besides the messages — tool schemas and the final_answer schema — and
# resumes against the snapshot, so a deploy that changes tools cannot fail
# parked work or silently swap the agent underneath an approval a human
# already gave. Pre-snapshot rows (nil column) keep the original loud-failure
# contract.
RSpec.describe "definitions snapshot" do
  include ActiveJob::TestHelper

  DEFS_A = [ { "name" => "record", "description" => "records a thing",
               "input_schema" => { "type" => "object", "properties" => {}, "required" => [] } } ].freeze
  DEFS_B = [ { "name" => "record", "description" => "records a thing DIFFERENTLY",
               "input_schema" => { "type" => "object", "properties" => {}, "required" => [] } },
             { "name" => "shred", "description" => "new tool from the deploy",
               "input_schema" => { "type" => "object", "properties" => {}, "required" => [] } } ].freeze

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "do the thing") }

  def gated_tool
    tool = Object.new
    tool.define_singleton_method(:effect_mode) { :at_most_once }
    tool.define_singleton_method(:approval_policy) { :always }
    tool.define_singleton_method(:call) { |**| { "ok" => true } }
    tool
  end

  def configure!(engine, tool, defs:, digest:)
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
      c.tool_definitions = -> { defs }
      c.definitions_digest = -> { digest }
    end
  end

  def deploy!(defs:, digest:)
    Silas.config.tool_definitions = -> { defs }
    Silas.config.definitions_digest = -> { digest }
  end

  def drain!
    20.times { break if enqueued_jobs.empty?; perform_enqueued_jobs }
  end

  it "stamps the model-visible definitions once, at turn start" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(0))
    configure!(engine, gated_tool, defs: DEFS_A, digest: "digest-a")

    Silas::AgentLoopJob.perform_now(turn.id)

    snapshot = turn.reload.definitions_snapshot
    expect(snapshot).to eq({ "tools" => DEFS_A, "final_answer" => nil })
    expect(turn.definitions_digest).to eq("digest-a")
  end

  it "resumes a parked turn against its snapshot after a deploy changes the tools" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    configure!(engine, gated_tool, defs: DEFS_A, digest: "digest-a")

    Silas::AgentLoopJob.perform_now(turn.id)
    inv = turn.reload.tool_invocations.sole
    expect(turn.status).to eq("waiting")

    deploy!(defs: DEFS_B, digest: "digest-b")

    inv.approve!(by: "daniel")
    drain!

    turn.reload
    expect(turn.status).to eq("completed")
    expect(turn.failure_reason).to be_nil
    # The model never saw the deploy: every step served the turn's snapshot.
    expect(engine.calls.map { |c| c[:tools] }).to all(eq(DEFS_A))
  end

  it "instruments the drift instead of failing the turn" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    configure!(engine, gated_tool, defs: DEFS_A, digest: "digest-a")

    Silas::AgentLoopJob.perform_now(turn.id)
    inv = turn.reload.tool_invocations.sole
    deploy!(defs: DEFS_B, digest: "digest-b")

    drifts = []
    subscription = ActiveSupport::Notifications.subscribe("definitions_drift.silas") do |*, payload|
      drifts << payload
    end
    begin
      inv.approve!(by: "daniel")
      drain!
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    expect(drifts).not_to be_empty
    expect(drifts.first).to include(turn_id: turn.id)
  end

  it "keeps the loud failure for pre-snapshot rows" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
    configure!(engine, gated_tool, defs: DEFS_A, digest: "digest-a")

    Silas::AgentLoopJob.perform_now(turn.id)
    inv = turn.reload.tool_invocations.sole

    # A row from before the snapshot column existed.
    turn.update!(definitions_snapshot: nil)
    deploy!(defs: DEFS_B, digest: "digest-b")

    inv.approve!(by: "daniel")
    expect { drain! }.to raise_error(Silas::NondeterminismError, /changed mid-turn/)
    expect(turn.reload).to have_attributes(status: "failed", failure_reason: "definitions_changed")
  end

  it "snapshots the final_answer schema alongside the tools" do
    engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(0))
    configure!(engine, gated_tool, defs: DEFS_A, digest: "digest-a")
    schema = { "type" => "object", "properties" => { "verdict" => { "type" => "string" } } }
    allow(Silas).to receive(:agent).and_wrap_original do |original, *args|
      agent = original.call(*args)
      allow(agent).to receive(:final_answer).and_return(schema)
      agent
    end

    Silas::AgentLoopJob.perform_now(turn.id)

    expect(turn.reload.definitions_snapshot["final_answer"]).to eq(schema)
    expect(engine.calls.first[:final_answer]).to eq(schema)
  end
end
