module Silas
  # Mandatory durability infrastructure (proven in the Phase 0 spike): Solid
  # Queue FAILS a dead worker's claimed jobs (ProcessExitError on supervisor
  # reap, ProcessPrunedError on heartbeat prune) and nothing retries them —
  # retry_on can't see queue-level errors. This job, run as a recurring task,
  # is the recovery path; recovery latency ≈ alive_threshold + its cadence.
  #
  # It also sweeps expired approvals while it's here.
  class DeadJobRescuerJob < ActiveJob::Base
    DEAD_PROCESS_ERRORS = %w[
      SolidQueue::Processes::ProcessExitError
      SolidQueue::Processes::ProcessPrunedError
    ].freeze

    queue_as { Silas.config.queue_name }

    def perform
      Silas.instrument(:rescue) { |payload| sweep(payload) }
    end

    def sweep(payload)
      ToolInvocation.expire_stale!
      payload[:rescued] = 0
      payload[:stranded] = 0
      return 0 unless defined?(SolidQueue)

      rescued = 0
      SolidQueue::FailedExecution.includes(:job).find_each do |failed|
        if DEAD_PROCESS_ERRORS.include?(failed.error&.dig("exception_class"))
          failed.retry
          rescued += 1
        elsif failed.job&.class_name == "Silas::AgentLoopJob"
          payload[:stranded] += 1 if fail_stranded_turn(failed)
        end
      end
      payload[:rescued] = rescued
      rescued
    end

    private

    # A loop job that failed with a NON-dead-process error (something outside
    # AgentLoopJob's retry list — a NoMethodError in a tool, an AR blip) will
    # never be retried by anyone. Without this sweep its turn sits in
    # "running" forever: not failed, not parked, invisible as broken. The
    # failed execution stays in Solid Queue for forensics; the TURN is failed
    # loudly with its approvals expired.
    def fail_stranded_turn(failed)
      turn = Turn.find_by(id: failed.job.arguments&.dig("arguments", 0))
      return false unless turn&.active?

      exception = failed.error&.dig("exception_class")
      turn.expire_pending_approvals!("turn failed: #{exception}")
      turn.finish!(:failed, reason: "job_failed")
      Rails.logger&.error("[silas] turn #{turn.id} failed: its loop job died with " \
                          "#{exception} — #{failed.error&.dig('message')}")
      true
    end
  end
end
