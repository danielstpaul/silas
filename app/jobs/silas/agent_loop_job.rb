module Silas
  # One durable turn. Step-name sequence: :prepare, :step_0, :step_1, …,
  # :finalize. Every between-step loop-control read hits write-once persisted
  # state (Step#terminal, invocation approval state at-or-after the cursor), so
  # a resumed continuation regenerates the IDENTICAL sequence — the spike's
  # hard-won determinism constraint, owned by the framework so users can't
  # violate it.
  #
  # Parking (approval / in-doubt) is a NORMAL job exit at zero compute; resume
  # is a fresh job enqueued by approve!/decline!, replaying completed steps
  # from rows (no model calls, no re-effects — StepRunner's replay path).
  class AgentLoopJob < ActiveJob::Base
    include ActiveJob::Continuable

    # Errors must reach retry_on. By default Continuable swallows any
    # StandardError raised after a checkpoint and silently self-resumes —
    # unbounded invisible retries that bypass attempts/wait/jitter entirely
    # (verified against activejob 8.1: the around_perform rescue runs before
    # rescue_with_handler). Checkpoints still survive retry_on's re-enqueues —
    # continuation state rides the job payload — so a retried execution skips
    # completed steps. Isolation interrupts are rescued separately and are
    # unaffected by this flag. Do NOT reach for max_resumptions as an error
    # bound: with isolate_steps on, every isolated step consumes one
    # resumption by design.
    self.resume_errors_after_advancing = false

    self.resume_options = { wait: 0 } # spike: default 5s wait makes turns crawl

    queue_as { Silas.config.queue_name }

    # Transient provider trouble: back off and retry; the continuation resumes
    # from the last completed step. Exhaustion fails the turn LOUDLY — a turn
    # must never strand in "running". (Never retry_on StandardError: it would
    # catch Continuation::Error subclasses and retry a structurally broken job
    # forever.)
    retry_on ::RubyLLM::RateLimitError, ::RubyLLM::OverloadedError,
             ::RubyLLM::ServiceUnavailableError, ::RubyLLM::ServerError,
             ::Faraday::TimeoutError, ::Faraday::ConnectionFailed,
             wait: :polynomially_longer, attempts: 5, jitter: 0.15 do |job, error|
      fail_turn(job, error)
    end

    # Permanent provider rejections: retrying cannot help. Fail the turn now.
    discard_on ::RubyLLM::UnauthorizedError, ::RubyLLM::PaymentRequiredError,
               ::RubyLLM::ForbiddenError, ::RubyLLM::BadRequestError do |job, error|
      fail_turn(job, error)
    end

    # The force-fail path: expire approvals FIRST so no stale card can
    # zombie-resume the failed turn, then finish loudly.
    def self.fail_turn(job, error)
      turn = Turn.find_by(id: job.arguments.first)
      return unless turn&.active?

      turn.expire_pending_approvals!("turn failed: model error")
      turn.finish!(:failed, reason: "model_error")
      Rails.logger&.error("[silas] turn #{turn.id} failed on #{error.class}: #{error.message}")
    end

    def perform(turn_id)
      turn = Turn.find(turn_id)
      return if turn.completed? || %w[failed canceled].include?(turn.status)

      # Named-agent / subagent sessions run EVERY turn under their own scope
      # (tools, skills, instructions, digest) — including resumes: a rescued
      # turn re-enters here and re-establishes the same scope, so a crashed
      # staff member never wakes up holding the root agent's tools.
      scope = Silas.scope_for_session(turn.session)
      if scope
        Silas.with_agent_scope(scope) { run_turn(turn) }
      else
        run_turn(turn)
      end
    end

    private

    # The framework drives the loop: one model call per step, tools executed
    # through the Ledger. The determinism constraints live here.
    def run_turn(turn)
      step :prepare, isolated: isolate? do
        Ledger.assert_no_checkpoint!
        turn.update!(status: "running", job_id: job_id, started_at: turn.started_at || Time.current)
        Instructions.snapshot!(turn)
      end

      index = 0
      loop do
        # Cancellation is honored at step boundaries only — the same safe point
        # as budgets. (Mutable-state read between steps: benign, like the
        # budget wall-clock check — a cancel landing later on resume is still
        # a correct cancel.)
        if turn.reload.cancel_requested_at
          turn.expire_pending_approvals!("turn canceled")
          turn.finish!(:canceled, reason: "canceled")
          return
        end

        step :"step_#{index}", isolated: isolate? do
          Ledger.assert_no_checkpoint!
          StepRunner.call(turn, index)
        end

        # Loop control reads persisted, effectively-immutable state only.
        row = Step.find_by!(turn: turn, index: index)
        return if row.parked?
        break if row.terminal?

        # Budget caps (cost/tokens/time) — checked between steps, never inside
        # one. A breach PARKS the turn (state intact, zero compute) rather than
        # failing it: a human tops up with turn.raise_budget! and the fresh job
        # replays completed steps from rows, resuming where it left off.
        if (reason = Budget.exceeded_reason(turn))
          turn.update!(status: "waiting", failure_reason: reason)
          Silas.instrument(:budget, reason: reason, turn_id: turn.id)
          Silas.instrument(:park, reason: "budget", turn_id: turn.id, detail: reason)
          return
        end

        index += 1
        if index >= Silas.agent.max_steps
          turn.finish!(:failed, reason: "max_steps")
          return
        end
      end

      step :finalize do
        turn.finish!(:completed)
      end
    end

    def isolate? = Silas.config.isolate_steps
  end
end
