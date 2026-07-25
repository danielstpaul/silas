require "rails_helper"

# 0.1.7: graph-shaped memory (triples + provenance + supersession, approval-
# gated writes) and staff handoffs (briefs through the ledger, no agent chatter).
RSpec.describe "memory and handoffs" do
  before { Silas::Registry.install!(root: DummyApp.root) }

  describe Silas::Memory do
    it "supersedes on the same subject+attribute, accumulates without attribute" do
      m1 = Silas::Memory.remember!(agent_name: "clerk", subject: "Author:Jane",
                                   attribute: "report_format", content: "prefers CSV")
      m2 = Silas::Memory.remember!(agent_name: "clerk", subject: "author:jane",
                                   attribute: "Report_Format", content: "now prefers XLSX")
      Silas::Memory.remember!(agent_name: "clerk", subject: "author:jane", content: "met at LBF")
      Silas::Memory.remember!(agent_name: "clerk", subject: "author:jane", content: "runs a newsletter")

      expect(m1.reload.status).to eq("superseded")
      expect(m1.superseded_by_id).to eq(m2.id)
      active = Silas::Memory.active.where(subject: "author:jane")
      expect(active.count).to eq(3) # the new triple + two free-form notes
      expect(active.where(attribute_name: "report_format").sole.content).to eq("now prefers XLSX")
    end

    it "recall sees own + app-shared, not other agents' private memories" do
      Silas::Memory.remember!(agent_name: "clerk", subject: "kdp", content: "clerk private")
      Silas::Memory.remember!(agent_name: "scout", subject: "kdp", content: "scout private")
      Silas::Memory.remember!(agent_name: "scout", subject: "kdp", content: "shared note", scope: "app")

      lines = Silas::Memory.recall(agent_name: "clerk").map(&:content)
      expect(lines).to include("clerk private", "shared note")
      expect(lines).not_to include("scout private")
    end
  end

  describe "remember tool" do
    it "parks for approval by default and writes exactly once on approve" do
      engine = FakeEngine.new do |context|
        if context[:index].zero?
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "noting" } ],
                               tool_calls: [ EngineScripts.tool_call("t0", "remember",
                                 subject: "author:jane", content: "prefers CSV", attribute: "report_format") ])
        else
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
        end
      end
      Silas.configure { |c| c.adapter = engine; c.isolate_steps = false }
      Silas::Registry.install!(root: DummyApp.root)

      session = Silas::Session.create!
      turn = session.turns.create!(index: 0, input: "remember jane's format")
      Silas::AgentLoopJob.perform_now(turn.id)

      expect(turn.reload.status).to eq("waiting")
      expect(Silas::Memory.count).to eq(0) # nothing persisted before the human

      inv = turn.tool_invocations.sole
      inv.approve!(by: "daniel")
      perform_enqueued_jobs_now
      expect(Silas::Memory.active.sole.content).to eq("prefers CSV")
      expect(Silas::Memory.sole.session_id).to eq(session.id)
    end

    it "auto-approves when memory_approval = :never" do
      Silas.config.memory_approval = :never
      policy = Silas::Tools::Remember.approval_policy
      session = Silas::Session.create!(agent_name: "clerk")
      expect(policy.call(session: session, input: {})).to eq(:approved)
    ensure
      Silas.config.memory_approval = :always
    end
  end

  describe "instructions injection" do
    it "surfaces recent memories in the snapshot" do
      Silas::Memory.remember!(agent_name: "agent", subject: "retailer:kdp",
                              attribute: "report_day", content: "reports arrive on the 15th")
      session = Silas::Session.create!
      turn = session.turns.create!(index: 0, input: "hello")
      Silas::Instructions.snapshot!(turn)
      expect(turn.instructions_snapshot).to include("## Memory")
      expect(turn.instructions_snapshot).to include("retailer:kdp · report_day: reports arrive on the 15th")
    end
  end

  describe "handoff tool" do
    def run_handoff(session, **args)
      t = Silas::Tools::Handoff.new
      t.session = session
      t.call(**args)
    end

    before do
      engine = FakeEngine.new do |_context|
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "brief handled" } ])
      end
      Silas.configure { |c| c.adapter = engine; c.isolate_steps = false }
      Silas::Registry.install!(root: DummyApp.root)
    end

    it "await: true runs the colleague inline and returns their answer" do
      session = Silas::Session.create!(agent_name: "scribe")
      out = run_handoff(session, agent: "filer", brief: "File the March summary.", await: true)
      expect(out["status"]).to eq("completed")
      expect(out["answer"]).to eq("brief handled")
      nested = Silas::Session.find(out["session_id"])
      expect(nested.agent_name).to eq("filer")
      expect(nested.parent_session_id).to eq(session.id)
    end

    it "await completes even under production isolate_steps (NestedRunner, not perform_now)" do
      Silas.config.isolate_steps = true
      session = Silas::Session.create!(agent_name: "scribe")
      out = run_handoff(session, agent: "filer", brief: "File it now.", await: true)
      expect(out["status"]).to eq("completed")
      expect(out["answer"]).to eq("brief handled")
    ensure
      Silas.config.isolate_steps = false
    end

    it "fire-and-forget enqueues and links" do
      session = Silas::Session.create!(agent_name: "scribe")
      out = run_handoff(session, agent: "filer", brief: "File it.")
      expect(out["status"]).to eq("queued")
      expect(Silas::Session.find(out["session_id"]).metadata["handoff_from"]).to eq("scribe")
    end

    it "refuses self, unknown targets, and cycles" do
      session = Silas::Session.create!(agent_name: "scribe")
      expect(run_handoff(session, agent: "scribe", brief: "x")["error"]).to match(/itself/)
      expect(run_handoff(session, agent: "butler", brief: "x")["error"]).to match(/unknown agent/)

      parent = Silas::Session.create!(agent_name: "filer")
      child = Silas::Session.create!(agent_name: "scribe", parent_session_id: parent.id)
      expect(run_handoff(child, agent: "filer", brief: "x")["error"]).to match(/cycle/)
    end
  end

  def perform_enqueued_jobs_now
    enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    enqueued.each { |j| ActiveJob::Base.execute(j) }
  end
end
