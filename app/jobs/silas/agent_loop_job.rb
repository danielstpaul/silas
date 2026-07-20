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

    self.resume_options = { wait: 0 } # spike: default 5s wait makes turns crawl

    queue_as { Silas.config.queue_name }

    def perform(turn_id)
      turn = Turn.find(turn_id)
      return if turn.completed? || %w[failed canceled].include?(turn.status)

      # Named-agent / subagent sessions run EVERY turn under their own scope
      # (tools, skills, instructions, digest) — including resumes: a rescued
      # turn re-enters here and re-establishes the same scope, so a crashed
      # staff member never wakes up holding the root agent's tools.
      scope = Silas.scope_for_session(turn.session)
      if scope
        Silas.with_agent_scope(scope) { drive(turn) }
      else
        drive(turn)
      end
    end

    private

    def drive(turn)
      if Silas.resolved_engine.class.loop_ownership == :engine
        perform_engine_owned(turn)
      else
        perform_framework_owned(turn)
      end
    end


    # :ruby_llm — the framework drives the loop, one model call per step, tools
    # executed through the Ledger. The determinism constraints live here.
    def perform_framework_owned(turn)
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

    # :agent_sdk — Claude Code owns the loop; one isolated :run step wraps the
    # whole subprocess (one Continuation checkpoint per invocation). Same
    # durable shell, same queue/rescuer/single-active-turn invariants.
    def perform_engine_owned(turn)
      step :prepare, isolated: isolate? do
        Ledger.assert_no_checkpoint!
        turn.update!(status: "running", job_id: job_id, started_at: turn.started_at || Time.current)
        Instructions.snapshot!(turn)
        Step.find_or_create_by!(turn: turn, index: 0) # anchor step exists before the MCP thread needs it
      end

      # Cancellation for engine-owned turns is honored only BEFORE the
      # subprocess starts — a running claude -p is not aborted mid-flight (v1).
      if turn.reload.cancel_requested_at
        turn.finish!(:canceled, reason: "canceled")
        return
      end

      outcome = nil
      step :run, isolated: isolate? do
        Ledger.assert_no_checkpoint!
        outcome = SubprocessRunner.call(turn)
      end

      step :finalize do
        turn.finish!(:completed) if outcome == :terminal
      end
    end

    def isolate? = Silas.config.isolate_steps
  end
end
