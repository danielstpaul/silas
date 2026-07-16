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
      ToolInvocation.expire_stale!
      return 0 unless defined?(SolidQueue)

      rescued = 0
      SolidQueue::FailedExecution.includes(:job).find_each do |failed|
        next unless DEAD_PROCESS_ERRORS.include?(failed.error&.dig("exception_class"))

        failed.retry
        rescued += 1
      end
      rescued
    end
  end
end
