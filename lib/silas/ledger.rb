module Silas
  # The three-state tool executor — the exactly-once machinery the spike proved.
  #
  # settle!(step, resolver:) walks the step's invocations in creation order and
  # drives each to a terminal state. Returns :completed when every invocation
  # settled, or :parked when one is awaiting a human (approval or in-doubt).
  #
  # State machine per invocation:
  #   pending  --approval fires--> pending + approval_state=required  (PARK)
  #   pending  --transactional-->  completed        (tool + row in ONE txn)
  #   pending  --at_most_once/idempotent--> started --> completed
  #   started  --found on replay, at_most_once--> in_doubt            (PARK)
  #   started  --found on replay, idempotent-->  re-run --> completed
  #   completed --> no-op (replay feeds the persisted result forward)
  #
  # Concurrency: claims are compare-and-swap UPDATEs (status='pending' in the
  # WHERE clause), so two executions racing the same invocation cannot both run
  # the tool. The unique (step_id, tool_call_id) index backstops row creation.
  module Ledger
    GUARD_KEY = :silas_ledger_transaction

    class << self
      # True while a ledger transaction is open on this thread. A continuation
      # checkpoint inside would raise Interrupt and roll back committed-looking
      # progress (spike finding #5) — AgentLoopJob asserts against this.
      def in_transaction? = Thread.current[GUARD_KEY] == true

      def assert_no_checkpoint!
        return unless in_transaction?

        raise CheckpointInLedgerError,
              "A continuation checkpoint was attempted inside a ledger transaction. " \
              "Checkpoints raise Interrupt, which would roll back tool side effects " \
              "the continuation believes are committed."
      end

      # Settle EVERY invocation in the step, then report whether the turn must
      # park. When the model emits parallel tool calls, an ungated one must not
      # be blocked by a gated sibling's approval — and it wouldn't be protected
      # anyway: an unsettled sibling executes on resume regardless of whether the
      # human approves or declines the gated call, so stopping at the first park
      # only delays independent work. Execute what can proceed; park if any
      # invocation is awaiting a human.
      def settle!(step, resolver:)
        parked = false
        step.tool_invocations.order(:id).each do |invocation|
          parked = true if settle_invocation!(invocation, resolver) == :parked
        end
        parked ? :parked : :completed
      end

      # Drive a SINGLE freshly-created invocation to a terminal state — the
      # :agent_sdk MCP endpoint creates one invocation per tools/call and needs
      # exactly the same exactly-once/effect-mode machinery as settle!. Returns
      # :done or :parked; the invocation carries its .result.
      def execute_invocation!(invocation, resolver:)
        settle_invocation!(invocation, resolver)
      end

      private

      def settle_invocation!(invocation, resolver)
        case invocation.status
        when "completed", "failed" then :done
        # approve! resets in_doubt -> pending+approved (re-execute); decline!
        # resolves it to failed with an operator-supplied outcome. So a row
        # still in_doubt here is by definition awaiting its human.
        when "in_doubt" then :parked
        when "started" then handle_in_doubt(invocation, resolver)
        when "pending" then execute_pending(invocation, resolver)
        end
      end

      def execute_pending(invocation, resolver)
        return :parked if invocation.awaiting_approval?

        tool = resolver.call(invocation.tool_name)

        unless invocation.approval_state == "approved"
          verdict = approval_verdict(tool, invocation)
          case verdict
          when :user_approval
            invocation.update!(approval_state: "required",
                               approval_expires_at: Silas.config.approval_ttl.from_now)
            return :parked
          when Hash # {denied: "reason"} — eve's shape
            invocation.update!(status: "failed", result: { "denied" => verdict[:denied] })
            return :done
          end
          # :not_applicable / :approved / :once-satisfied fall through
        end

        execute!(invocation, tool)
      end

      def execute!(invocation, tool)
        tool.session = invocation.turn.session if tool.respond_to?(:session=)
        args = invocation.arguments.symbolize_keys

        if invocation.effect_mode == "transactional"
          # Tool side effects + ledger completion commit or roll back together:
          # exactly-once for DB-backed tools (spike cell C).
          guarded_transaction do
            next :done unless claim!(invocation, from: "pending", to: "completed")

            result = tool.call(**args)
            invocation.update!(result: wrap_result(result))
          end
        else
          # External effects: mark started (committed), call, mark completed.
          # A crash between the two commits is the in-doubt window.
          return :done unless claim!(invocation, from: "pending", to: "started")

          result = tool.call(**args)
          invocation.update!(status: "completed", result: wrap_result(result))
        end
        :done
      rescue StandardError => e
        raise if e.is_a?(Silas::Error)

        invocation.update!(status: "failed", error: "#{e.class}: #{e.message}")
        :done
      end

      # started + replay = the tool may or may not have run (spike's in-doubt).
      def handle_in_doubt(invocation, resolver)
        if invocation.effect_mode == "idempotent"
          tool = resolver.call(invocation.tool_name)
          tool.session = invocation.turn.session if tool.respond_to?(:session=)
          result = tool.call(**invocation.arguments.symbolize_keys)
          invocation.update!(status: "completed", result: wrap_result(result))
          :done
        else
          # at_most_once (default): park for a human verdict via the approval
          # machinery — approve! = "it did not run, re-execute";
          # decline! = "it ran / abandon", operator supplies the outcome.
          invocation.update!(status: "in_doubt", approval_state: "required",
                             approval_expires_at: Silas.config.approval_ttl.from_now)
          :parked
        end
      end

      def approval_verdict(tool, invocation)
        policy = tool.respond_to?(:approval_policy) ? tool.approval_policy : :never
        case policy
        when :never then :not_applicable
        when :always then :user_approval
        when :once
          previously_approved?(invocation) ? :approved : :user_approval
        when Proc
          # Indifferent access: arguments are stored as jsonb (string keys),
          # but a lambda writing input[:amount] must not get a silent nil.
          policy.call(session: invocation.turn.session,
                      input: invocation.arguments.with_indifferent_access)
        else
          :not_applicable
        end
      end

      def previously_approved?(invocation)
        ToolInvocation.joins(:turn)
                      .where(silas_turns: { session_id: invocation.turn.session_id },
                             tool_name: invocation.tool_name, approval_state: "approved")
                      .where.not(id: invocation.id)
                      .exists?
      end

      # Compare-and-swap claim: only one racing execution wins.
      def claim!(invocation, from:, to:)
        claimed = ToolInvocation.where(id: invocation.id, status: from)
                                .update_all(status: to, updated_at: Time.current) == 1
        invocation.reload if claimed
        claimed
      end

      def guarded_transaction
        Thread.current[GUARD_KEY] = true
        ApplicationRecord.transaction { yield }
      ensure
        Thread.current[GUARD_KEY] = false
      end

      def wrap_result(result)
        result.is_a?(Hash) ? result : { "value" => result }
      end
    end
  end
end
