require "rails_helper"

# The durable loop used to be silent: a turn could start, park for a human,
# get rescued after a kill -9, breach a budget and finish without emitting a
# line. These specs pin the event NAMES and PAYLOAD KEYS, because those are a
# public contract — dashboards and APM spans are built on them, and a silent
# rename breaks someone's alerting.
RSpec.describe "instrumentation" do
  include ActiveJob::TestHelper

  def capture(pattern = /\.silas\z/)
    events = []
    sub = ActiveSupport::Notifications.subscribe(pattern) do |name, start, finish, _id, payload|
      events << { name: name, duration: (finish - start) * 1000, payload: payload }
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "go", status: "running") }
  let(:step) { Silas::Step.create!(turn: turn, index: 0, status: "completed") }

  def invocation!(**attrs)
    Silas::ToolInvocation.create!({ step: step, turn: turn, tool_call_id: "t0",
                                    tool_name: "issue_refund", effect_mode: "transactional",
                                    arguments: { "amount" => 10 } }.merge(attrs))
  end

  def tool_double(approval: :never)
    tool = Object.new
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**| { "ok" => true } }
    tool
  end

  it "names every event <event>.silas (the Rails convention), so one subscriber catches all" do
    events = capture { turn.finish!(:completed) }
    expect(events.map { |e| e[:name] }).to all(match(/\.silas\z/))
    expect(events.map { |e| e[:name] }).to include("turn.silas")
  end

  describe "turn.silas" do
    it "carries status, reason, and correlation ids" do
      events = capture("turn.silas") { turn.finish!(:failed, reason: "model_error") }
      payload = events.sole[:payload]
      expect(payload).to include(status: "failed", reason: "model_error",
                                 turn_id: turn.id, session_id: session.id)
      expect(payload).to have_key(:steps)
      expect(payload).to have_key(:agent)
    end
  end

  describe "tool.silas — the most valuable span" do
    it "times the tool's own execution and reports how it settled" do
      inv = invocation!
      events = capture("tool.silas") do
        Silas::Ledger.settle!(step, resolver: ->(_n) { tool_double })
      end

      payload = events.sole[:payload]
      expect(payload).to include(tool: "issue_refund", effect_mode: "transactional",
                                 status: "completed", turn_id: turn.id, invocation_id: inv.id)
      expect(events.sole[:duration]).to be >= 0
    end

    it "reports a failed tool without swallowing the failure" do
      invocation!
      exploding = Object.new
      exploding.define_singleton_method(:approval_policy) { :never }
      exploding.define_singleton_method(:call) { |**| raise "bank exploded" }

      events = capture("tool.silas") do
        Silas::Ledger.settle!(step, resolver: ->(_n) { exploding })
      end
      expect(events.sole[:payload][:status]).to eq("failed")
    end
  end

  describe "park.silas / resume.silas — the human-in-the-loop latency story" do
    it "emits a park when a gate holds a call, with the reason and the tool" do
      invocation!
      events = capture("park.silas") do
        Silas::Ledger.settle!(step, resolver: ->(_n) { tool_double(approval: :always) })
      end
      expect(events.sole[:payload]).to include(reason: "approval", turn_id: turn.id,
                                               detail: "issue_refund")
    end

    it "emits a resume carrying how long the human took" do
      inv = invocation!(approval_state: "required", status: "pending")
      turn.update!(status: "waiting", updated_at: 90.seconds.ago)

      events = capture("resume.silas") { inv.approve!(by: "ada") }
      payload = events.sole[:payload]
      expect(payload[:turn_id]).to eq(turn.id)
      expect(payload[:parked_for]).to be_within(10).of(90)
    end
  end

  describe "approval.silas" do
    it "records who settled it, and how" do
      inv = invocation!(approval_state: "required", status: "pending")
      events = capture("approval.silas") { inv.approve!(by: "ada") }
      expect(events.sole[:payload]).to include(action: "approved", tool: "issue_refund", by: "ada")

      inv2 = invocation!(tool_call_id: "t1", approval_state: "required", status: "pending")
      declined = capture("approval.silas") { inv2.decline!(reason: "too much", by: "cfo") }
      expect(declined.sole[:payload]).to include(action: "declined", by: "cfo")
    end

    it "records an expiry from the sweeper" do
      invocation!(approval_state: "required", status: "pending",
                  approval_expires_at: 1.hour.ago)
      events = capture("approval.silas") { Silas::ToolInvocation.expire_stale! }
      expect(events.sole[:payload]).to include(action: "expired", tool: "issue_refund")
    end
  end

  describe "budget.silas" do
    it "emits the breached limit and a matching park" do
      allow(Silas).to receive(:agent)
        .and_return(Silas::Agent.new("limits" => { "max_input_tokens" => 10, "max_steps" => 5 }))
      Silas.configure do |c|
        c.adapter = FakeEngine.new do |ctx|
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "s#{ctx[:index]}" } ],
                               tool_calls: [ EngineScripts.tool_call("t#{ctx[:index]}") ])
                       .tap { |r| r.usage[:input_tokens] = 5_000 }
        end
        c.isolate_steps = false
        c.tool_resolver = ->(_n) { tool_double }
      end

      t = Silas::Turn.create!(session: session, index: 1, input: "loop")
      events = capture(/\A(budget|park)\.silas\z/) { Silas::AgentLoopJob.perform_now(t.id) }

      expect(events.map { |e| e[:name] }).to include("budget.silas", "park.silas")
      expect(events.find { |e| e[:name] == "budget.silas" }[:payload])
        .to include(reason: "max_input_tokens", turn_id: t.id)
    end
  end

  describe "rescue.silas" do
    it "reports what the sweeper actually did" do
      relation = double("relation", find_each: nil)
      allow(SolidQueue::FailedExecution).to receive(:includes).and_return(relation)

      events = capture("rescue.silas") { Silas::DeadJobRescuerJob.perform_now }
      expect(events.sole[:payload]).to include(rescued: 0, stranded: 0)
    end
  end

  describe "the LogSubscriber" do
    let(:output) { StringIO.new }

    around do |example|
      previous = Silas.logger
      logger = ActiveSupport::Logger.new(output)
      # Severity is the point of these assertions, so make it visible.
      logger.formatter = ->(severity, _time, _prog, msg) { "#{severity} #{msg}\n" }
      Silas.logger = logger
      example.run
    ensure
      Silas.logger = previous
    end

    def event_for(name, payload, ms: 50)
      started = Time.current
      ActiveSupport::Notifications::Event.new(name, started, started + (ms / 1000.0), "id", payload)
    end

    it "formats with the version, action, duration, and attributes" do
      Silas::LogSubscriber.new.turn(
        event_for("turn.silas", { status: "completed", turn_id: 7, session_id: 3, steps: 2 })
      )

      expect(output.string).to match(/Silas-#{Regexp.escape(Silas::VERSION)} Turn completed \(50\.0ms\)/)
      expect(output.string).to include("turn_id: 7")
    end

    it "logs a failed turn at ERROR and a park at INFO — levels an operator can filter on" do
      subscriber = Silas::LogSubscriber.new
      subscriber.turn(event_for("turn.silas", { status: "failed", reason: "model_error", turn_id: 7 }))
      subscriber.park(event_for("park.silas", { reason: "approval", turn_id: 7, detail: "issue_refund" }))

      expect(output.string).to match(/ERROR.*Turn failed/)
      expect(output.string).to match(/INFO.*Turn parked \(approval\)/)
    end

    it "stays quiet when the rescuer did nothing (no noise every 30 seconds)" do
      Silas::LogSubscriber.new.rescue(event_for("rescue.silas", { rescued: 0, stranded: 0 }))
      expect(output.string).to be_empty
    end
  end
end
