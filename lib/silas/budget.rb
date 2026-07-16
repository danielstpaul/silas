module Silas
  # Per-turn budget caps beyond max_steps: cumulative input tokens, cost, and
  # wall-clock. Checked between steps in the framework-owned loop (never inside a
  # continuation step). A breach PARKS the turn at zero compute (like an
  # approval); a human resumes it with Turn#raise_budget!, which records a
  # per-turn override consulted here ahead of the agent's limits.
  #
  # Token/cost checks are deterministic (persisted step data). The timeout check
  # reads the wall clock — benign non-determinism: a cap firing later on resume
  # is correct (the turn genuinely ran too long across the crash). Note the
  # timeout clock includes time spent parked, so a timeout top-up should be
  # sized from Time.current - started_at, not from the original limit.
  module Budget
    REASONS = %w[max_input_tokens max_cost timeout].freeze

    module_function

    # Returns a limit-reason string if a cap is exceeded, else nil.
    def exceeded_reason(turn, agent: Silas.agent)
      return "max_input_tokens" if over_tokens?(turn, agent)
      return "max_cost" if over_cost?(turn, agent)
      return "timeout" if over_time?(turn, agent)

      nil
    end

    # A human top-up (turn.budget_overrides) beats the agent's configured limit.
    def limit_for(turn, agent, key)
      override = turn.budget_overrides&.dig(key.to_s)
      override.nil? ? agent.public_send(key) : override
    end

    def over_tokens?(turn, agent)
      limit = limit_for(turn, agent, :max_input_tokens) or return false

      Silas::Step.where(turn_id: turn.id).sum(:input_tokens) > limit
    end

    def over_cost?(turn, agent)
      limit = limit_for(turn, agent, :max_cost) or return false

      spent = Silas::Inbox::Cost.for_turn(turn)
      # Only enforce on priced tokens; unpriced models can't be cost-capped.
      spent[:microcents] > (limit.to_f * 1_000_000)
    end

    def over_time?(turn, agent)
      limit = limit_for(turn, agent, :timeout) or return false
      return false unless turn.started_at

      (Time.current - turn.started_at) > limit
    end
  end
end
