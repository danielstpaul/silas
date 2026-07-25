module Silas
  # ActiveSupport::Notifications for the durable loop.
  #
  # Until now the loop was silent: a turn could start, park for a human, get
  # rescued after a kill -9, breach a budget, and finish — without emitting a
  # single line. This is the seam for logs, APM spans, and metrics.
  #
  # Names follow the Rails convention `<event>.silas` (like `sql.active_record`),
  # so `ActiveSupport::Notifications.subscribe(/\.silas\z/)` gets everything.
  #
  #   ActiveSupport::Notifications.subscribe("tool.silas") do |event|
  #     StatsD.timing("agent.tool", event.duration, tags: ["tool:#{event.payload[:tool]}"])
  #   end
  #
  # ## Events and payloads
  #
  # Every payload carries `turn_id` and `session_id` where they exist, so any
  # subscriber can correlate without joining.
  #
  #   turn.silas       status:, reason:, steps:, session_id:, turn_id:, agent:
  #                    Duration = the whole turn INCLUDING parked time.
  #   step.silas       index:, model:, turn_id:  (one model call)
  #   tool.silas       tool:, effect_mode:, status:, approval_state:,
  #                    invocation_id:, turn_id:
  #                    Duration = the tool's own execution. The single most
  #                    useful span in the system.
  #   delta.silas      session_id:, turn_id:, step_id:, step_index:, text:
  #                    Streamed text so far (see DeltaBuffer). High frequency.
  #   park.silas       reason: (approval | question | in_doubt | budget),
  #                    turn_id:, detail:
  #   resume.silas     turn_id:, parked_for: (seconds a human took)
  #   approval.silas   action: (approved | answered | declined | expired),
  #                    tool:, by:, invocation_id:, turn_id:
  #   budget.silas     reason: (max_cost | max_input_tokens | timeout), turn_id:
  #   compact.silas    session_id:, turn_id:, up_to_turn_index:, tokens_before:,
  #                    input_tokens:, output_tokens:, model:
  #                    Duration = the summarisation model call.
  #   rescue.silas     rescued: (jobs retried), stranded: (turns failed)
  #   nondeterminism.silas  turn_id:, was:, now:  (digest changed mid-turn)
  module Instrumentation
    module_function

    def instrument(event, **payload, &block)
      ActiveSupport::Notifications.instrument("#{event}.silas", **payload, &block)
    end
  end

  # Silas.instrument(:tool, tool: "issue_refund") { ... }
  def self.instrument(event, **payload, &block)
    Instrumentation.instrument(event, **payload, &block)
  end

  # The logger Silas writes through; hosts can point it elsewhere.
  mattr_accessor :logger, default: nil

  def self.logger
    @@logger ||= (defined?(Rails) && Rails.logger) || ActiveSupport::Logger.new($stdout)
  end
end
