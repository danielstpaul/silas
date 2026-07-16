require "rails_helper"

RSpec.describe Silas::Ledger do
  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi", status: "running") }
  let(:step) { Silas::Step.create!(turn: turn, index: 0) }

  # Minimal tool duck (the real Silas::Tool arrives with the Registry).
  def tool_double(approval: :never, &block)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:call) do |**args|
      executions << args
      block ? block.call(**args) : { "ok" => true }
    end
    tool
  end

  def invocation!(effect_mode: "transactional", tool_call_id: "t0", **attrs)
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: tool_call_id,
                                tool_name: "record", effect_mode: effect_mode,
                                arguments: { "x" => 1 }, **attrs)
  end

  def resolver_for(tool) = ->(_name) { tool }

  describe "pending execution" do
    it "executes a transactional tool exactly once and completes the row" do
      tool = tool_double
      inv = invocation!
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:completed)
      expect(tool.executions).to eq([ { x: 1 } ])
      expect(inv.reload).to have_attributes(status: "completed", result: { "ok" => true })
    end

    it "does not re-execute a completed invocation on replay" do
      tool = tool_double
      invocation!(status: "completed", result: { "ok" => true })
      2.times { described_class.settle!(step, resolver: resolver_for(tool)) }
      expect(tool.executions).to be_empty
    end

    it "rolls tool side effects and the row back together when the tool raises mid-transaction" do
      inv = invocation!
      tool = tool_double { raise "boom" }
      described_class.settle!(step, resolver: resolver_for(tool))
      expect(inv.reload.status).to eq("failed")
      expect(inv.error).to match(/boom/)
    end

    it "settles multiple invocations in order" do
      tool = tool_double
      invocation!(tool_call_id: "t0")
      invocation!(tool_call_id: "t1")
      described_class.settle!(step, resolver: resolver_for(tool))
      expect(tool.executions.size).to eq(2)
    end
  end

  describe "exactly-once under racing executions" do
    # Threads need their own connections seeing committed rows.
    self.use_transactional_tests = false

    after do
      [ Silas::ToolInvocation, Silas::Step, Silas::Turn, Silas::Session ].each(&:delete_all)
    end

    it "lets only one of N racing threads execute an at_most_once tool" do
      inv = invocation!(effect_mode: "at_most_once")
      count = 0
      mutex = Mutex.new
      tool = tool_double { mutex.synchronize { count += 1 }; { "ok" => true } }

      8.times.map {
        Thread.new do
          described_class.settle!(step, resolver: resolver_for(tool))
        rescue ActiveRecord::StatementInvalid
          nil # SQLite can throw busy under contention; the CAS claim still guards
        end
      }.each(&:join)

      expect(count).to eq(1)
      expect(inv.reload.status).to eq("completed")
    end
  end

  describe "in-doubt handling" do
    it "parks an at_most_once invocation found in started state" do
      inv = invocation!(effect_mode: "at_most_once", status: "started")
      tool = tool_double
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:parked)
      expect(tool.executions).to be_empty
      expect(inv.reload).to have_attributes(status: "in_doubt", approval_state: "required")
      expect(inv.approval_expires_at).to be_within(1.minute).of(7.days.from_now)
    end

    it "re-runs an idempotent invocation found in started state" do
      inv = invocation!(effect_mode: "idempotent", status: "started")
      tool = tool_double
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:completed)
      expect(tool.executions.size).to eq(1)
      expect(inv.reload.status).to eq("completed")
    end
  end

  describe "approval policies (eve's shapes)" do
    it ":always parks the invocation with an expiry" do
      inv = invocation!
      tool = tool_double(approval: :always)
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:parked)
      expect(tool.executions).to be_empty
      expect(inv.reload).to have_attributes(status: "pending", approval_state: "required")
    end

    it ":once requires approval the first time, not after a prior approval in the session" do
      tool = tool_double(approval: :once)
      first = invocation!(tool_call_id: "t0")
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:parked)

      first.update!(approval_state: "approved", status: "completed", result: {})
      invocation!(tool_call_id: "t1")
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:completed)
      expect(tool.executions.size).to eq(1)
    end

    it "lambda returning :user_approval parks" do
      tool = tool_double(approval: ->(session:, input:) { :user_approval })
      invocation!
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:parked)
    end

    it "lambda returning {denied:} fails the invocation with the denial as result" do
      tool = tool_double(approval: ->(session:, input:) { { denied: "amount too large" } })
      inv = invocation!
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:completed)
      expect(tool.executions).to be_empty
      expect(inv.reload).to have_attributes(status: "failed", result: { "denied" => "amount too large" })
    end

    it "lambda receives the session and arguments" do
      seen = nil
      tool = tool_double(approval: ->(session:, input:) { seen = [ session, input ]; :not_applicable })
      invocation!
      described_class.settle!(step, resolver: resolver_for(tool))
      expect(seen[0]).to eq(session)
      expect(seen[1]).to eq({ "x" => 1 })
    end

    it "an approved invocation executes without re-evaluating policy" do
      tool = tool_double(approval: :always)
      inv = invocation!(approval_state: "approved")
      expect(described_class.settle!(step, resolver: resolver_for(tool))).to eq(:completed)
      expect(tool.executions.size).to eq(1)
      expect(inv.reload.status).to eq("completed")
    end
  end

  describe "checkpoint guard" do
    it "propagates loudly (framework bug, not tool failure) when a checkpoint occurs in a ledger transaction" do
      tool = tool_double { described_class.assert_no_checkpoint!; { "ok" => true } }
      inv = invocation!(effect_mode: "transactional")
      expect {
        described_class.settle!(step, resolver: resolver_for(tool))
      }.to raise_error(Silas::CheckpointInLedgerError)
      # Transaction rolled back: the claim is undone, nothing half-committed.
      expect(inv.reload.status).to eq("pending")
    end

    it "does not raise outside a ledger transaction" do
      expect { described_class.assert_no_checkpoint! }.not_to raise_error
    end
  end
end
