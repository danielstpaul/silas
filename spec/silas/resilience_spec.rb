require "rails_helper"

# Model-call resilience: transient provider errors retry with backoff and
# RESUME FROM THE CHECKPOINT (the load-bearing claim — verified here, not
# assumed); exhaustion and permanent rejections fail the turn loudly; nothing
# ever strands in "running".
RSpec.describe "model-call resilience" do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "go") }

  # Step 0: text + one tool call. Step 1: raises `error` fail_times times,
  # then completes the turn.
  class FlakyEngine < Silas::Adapters::Base
    attr_reader :calls

    def initialize(fail_times:, error:)
      @calls = []
      @remaining = fail_times
      @error = error
    end

    def execute_step(context, &)
      @calls << context[:index]
      if context[:index] == 1 && @remaining.positive?
        @remaining -= 1
        raise @error
      end

      tool_calls = context[:index].zero? ? [ Silas::Adapters::ToolCall.new(id: "t0", name: "record", arguments: {}) ] : []
      Silas::Adapters::Result.new(
        blocks: [ { "type" => "text", "text" => "step #{context[:index]}" } ],
        tool_calls: tool_calls,
        stop_reason: tool_calls.any? ? "tool_use" : "end_turn",
        usage: {}
      )
    end
  end

  def recording_tool
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { :transactional }
    tool.define_singleton_method(:approval_policy) { :never }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true } }
    tool
  end

  def configure!(engine, tool)
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false
      c.tool_resolver = ->(_name) { tool }
    end
  end

  it "retries a transient error from the last checkpoint — step 0 runs exactly once" do
    engine = FlakyEngine.new(fail_times: 1, error: RubyLLM::RateLimitError.new(nil, "429"))
    tool = recording_tool
    configure!(engine, tool)

    perform_enqueued_jobs { Silas::AgentLoopJob.perform_later(turn.id) }

    expect(turn.reload.status).to eq("completed")
    expect(engine.calls).to eq([ 0, 1, 1 ])   # checkpoint skipped step 0 on the retry
    expect(tool.executions.size).to eq(1)     # exactly-once effect straight through the retry
  end

  it "fails the turn loudly when retries exhaust — never a stranded running" do
    engine = FlakyEngine.new(fail_times: 99, error: RubyLLM::OverloadedError.new(nil, "529"))
    configure!(engine, recording_tool)

    perform_enqueued_jobs { Silas::AgentLoopJob.perform_later(turn.id) }

    expect(turn.reload).to have_attributes(status: "failed", failure_reason: "model_error")
    expect(engine.calls.count { |i| i == 1 }).to eq(5) # attempts: 5, then the exhausted block
  end

  it "fails immediately on a permanent provider rejection (no retries)" do
    engine = FlakyEngine.new(fail_times: 99, error: RubyLLM::UnauthorizedError.new(nil, "bad key"))
    configure!(engine, recording_tool)

    perform_enqueued_jobs { Silas::AgentLoopJob.perform_later(turn.id) }

    expect(turn.reload).to have_attributes(status: "failed", failure_reason: "model_error")
    expect(engine.calls).to eq([ 0, 1 ]) # one attempt at the failing step, discarded
  end

  describe "the force-fail path" do
    let!(:step) { Silas::Step.create!(turn: turn, index: 0) }
    let!(:invocation) do
      Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0",
                                    tool_name: "record", effect_mode: "at_most_once",
                                    arguments: {}, approval_state: "required")
    end

    it "expires pending approvals so no live card survives the failure" do
      turn.update!(status: "running")
      Silas::AgentLoopJob.fail_turn(Silas::AgentLoopJob.new(turn.id), RuntimeError.new("boom"))

      expect(turn.reload).to have_attributes(status: "failed", failure_reason: "model_error")
      expect(invocation.reload.approval_state).to eq("expired")
    end

    it "refuses to zombie-resume a failed turn from a stale approval card" do
      turn.update!(status: "failed", failure_reason: "model_error")

      expect { invocation.approve!(by: "op") }
        .to raise_error(Silas::Error, /already failed/)
      expect { invocation.decline!(reason: "no", by: "op") }
        .to raise_error(Silas::Error, /already failed/)
      expect(turn.reload.status).to eq("failed") # nothing re-enqueued
    end
  end

  describe "the stranded-turn sweeper" do
    def fake_failed_execution(exception_class:, job_class: "Silas::AgentLoopJob", turn_id: turn.id)
      job = double("SolidQueue::Job", class_name: job_class,
                                      arguments: { "arguments" => [ turn_id ] })
      double("SolidQueue::FailedExecution",
             error: { "exception_class" => exception_class, "message" => "boom" }, job: job)
    end

    def stub_failed_executions(*failed)
      relation = double("relation")
      allow(relation).to receive(:find_each) { |&blk| failed.each(&blk) }
      failed_execution = double("FailedExecution", includes: relation)
      stub_const("SolidQueue::FailedExecution", failed_execution)
      stub_const("SolidQueue::Processes", Module.new) # just to make SolidQueue defined
    end

    it "fails an active turn whose loop job died with an error outside the retry list" do
      turn.update!(status: "running")
      stub_failed_executions(fake_failed_execution(exception_class: "NoMethodError"))

      Silas::DeadJobRescuerJob.perform_now

      expect(turn.reload).to have_attributes(status: "failed", failure_reason: "job_failed")
    end

    it "still retries dead-process failures instead of failing their turns" do
      turn.update!(status: "running")
      failed = fake_failed_execution(exception_class: "SolidQueue::Processes::ProcessExitError")
      expect(failed).to receive(:retry)
      stub_failed_executions(failed)

      Silas::DeadJobRescuerJob.perform_now

      expect(turn.reload.status).to eq("running") # rescued, not failed
    end

    it "leaves non-loop jobs and settled turns alone" do
      turn.update!(status: "completed")
      stub_failed_executions(
        fake_failed_execution(exception_class: "NoMethodError"),
        fake_failed_execution(exception_class: "NoMethodError", job_class: "SomeOtherJob")
      )

      Silas::DeadJobRescuerJob.perform_now

      expect(turn.reload.status).to eq("completed")
    end
  end
end
