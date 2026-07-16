require "rails_helper"

RSpec.describe "channels" do
  include ActiveJob::TestHelper

  before do
    Silas::Registry.install!(root: DummyApp.root)
    Agent::Channels::Recorder.reset!
  end

  def recording_tool(approval: :never)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { :at_most_once }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:session=) { |s| @session = s }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true } }
    tool
  end

  def configure!(tool)
    Silas.configure do |c|
      c.engine = FakeEngine.new(&EngineScripts.n_tool_steps_then_done(1))
      c.isolate_steps = false
    end
    Silas::Registry.install!(root: DummyApp.root) # wires the real channel_resolver...
    Silas.config.tool_resolver = ->(_name) { tool } # ...then inject the fake tool resolver
  end

  def drain! = 20.times { break if enqueued_jobs.empty?; perform_enqueued_jobs }

  describe Silas::Channel do
    it "discovers channels by filename and keeps them out of the definitions digest" do
      before_digest = Silas::Registry.new(root: DummyApp.root).digest
      resolver = Silas.config.channel_resolver
      expect(resolver.call("recorder")).to eq(Agent::Channels::Recorder)
      expect(before_digest).to eq(Silas::Registry.new(root: DummyApp.root).digest)
    end

    it "dispatch starts a session on a new thread and continues on a reply" do
      configure!(recording_tool)

      s1 = Agent::Channels::Recorder.dispatch(thread_key: "T1", input: "hello")
      expect(s1.channel).to eq("recorder")
      expect(s1.continuation_token).to eq("recorder:T1")
      expect(s1.turns.sole.input).to eq("hello")
      drain!

      s2 = Agent::Channels::Recorder.dispatch(thread_key: "T1", input: "follow up")
      expect(s2.id).to eq(s1.id)                 # same thread -> same session
      expect(s2.turns.count).to eq(2)
    end

    it "raises TurnInProgressError on a reply while a turn is active" do
      configure!(recording_tool(approval: :always)) # first turn parks and stays active
      Agent::Channels::Recorder.dispatch(thread_key: "T2", input: "start")
      expect {
        Agent::Channels::Recorder.dispatch(thread_key: "T2", input: "impatient")
      }.to raise_error(Silas::TurnInProgressError)
    end

    it "round-trips a signed approve/decline token, rejecting tampered ones" do
      token = Silas::Channel.token_for(Struct.new(:id).new(42), "approve")
      expect(Silas::Channel.verify_token(token)).to eq("id" => 42, "action" => "approve")
      expect(Silas::Channel.verify_token(token + "x")).to be_nil
    end
  end

  describe "outbound delivery (the durable path, observed through a channel)" do
    it "delivers the answer exactly once when a channel-bound turn completes" do
      configure!(recording_tool)
      session = Agent::Channels::Recorder.dispatch(thread_key: "A1", input: "do it")
      drain!

      expect(session.turns.sole.reload.status).to eq("completed")
      expect(Agent::Channels::Recorder.answers.size).to eq(1)
      expect(Agent::Channels::Recorder.answers.first[:text]).to eq("done")
    end

    it "pings the channel once on approval-park, then delivers the answer after approve!" do
      tool = recording_tool(approval: :always)
      configure!(tool)

      session = Agent::Channels::Recorder.dispatch(thread_key: "A2", input: "refund")
      drain!

      # Parked -> exactly one approval ping.
      inv = session.reload.pending_approvals.sole
      expect(Agent::Channels::Recorder.approvals.size).to eq(1)
      expect(Agent::Channels::Recorder.approvals.first[:invocation_id]).to eq(inv.id)
      expect(tool.executions).to be_empty

      # Delivery job is idempotent: running it again sends nothing new.
      Silas::ChannelDeliveryJob.perform_now("approval", inv.id)
      expect(Agent::Channels::Recorder.approvals.size).to eq(1)

      # Approve -> fresh job resumes, exactly-once execution, answer delivered once.
      inv.approve!(by: "tester")
      drain!

      expect(session.turns.sole.reload.status).to eq("completed")
      expect(tool.executions.size).to eq(1)
      expect(Agent::Channels::Recorder.answers.size).to eq(1)
    end

    it "does not notify for a session with no channel" do
      configure!(recording_tool)
      session = Silas.agent.start(input: "no channel")
      drain!
      expect(session.turns.sole.reload.status).to eq("completed")
      expect(Agent::Channels::Recorder.answers).to be_empty
    end

    it "releases the claim and re-delivers if a send raises" do
      configure!(recording_tool)
      session = Agent::Channels::Recorder.dispatch(thread_key: "A3", input: "x")
      drain!
      turn = session.turns.sole.reload
      expect(turn.answered_at).to be_present # claimed by the successful delivery

      # Simulate a fresh unclaimed turn whose delivery raises, then succeeds.
      turn.update_columns(answered_at: nil)
      calls = 0
      allow_any_instance_of(Agent::Channels::Recorder).to receive(:deliver_answer) do
        calls += 1
        raise "smtp down" if calls == 1
      end
      expect { Silas::ChannelDeliveryJob.perform_now("answer", turn.id) }.to raise_error(/smtp down/)
      expect(turn.reload.answered_at).to be_nil # claim released
      Silas::ChannelDeliveryJob.perform_now("answer", turn.id) # retry succeeds
      expect(turn.reload.answered_at).to be_present
    end
  end
end
