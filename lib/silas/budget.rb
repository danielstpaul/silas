module Silas
  # Per-turn budget caps beyond max_steps: cumulative input tokens, cost, and
  # wall-clock. Checked between steps in the framework-owned loop (never inside a
  # continuation step), so a breach fails the turn cleanly with a limit reason.
  #
  # Token/cost checks are deterministic (persisted step data). The timeout check
  # reads the wall clock — benign non-determinism: a cap firing later on resume
  # is correct (the turn genuinely ran too long across the crash).
  module Budget
    module_function

    # Returns a failure reason string if a cap is exceeded, else nil.
    def exceeded_reason(turn, agent: Silas.agent)
      return "max_input_tokens" if over_tokens?(turn, agent)
      return "max_cost" if over_cost?(turn, agent)
      return "timeout" if over_time?(turn, agent)

      nil
    end

    def over_tokens?(turn, agent)
      limit = agent.max_input_tokens or return false

      Silas::Step.where(turn_id: turn.id).sum(:input_tokens) > limit
    end

    def over_cost?(turn, agent)
      limit = agent.max_cost or return false

      spent = Silas::Inbox::Cost.for_turn(turn)
      # Only enforce on priced tokens; unpriced models can't be cost-capped.
      spent[:microcents] > (limit.to_f * 1_000_000)
    end

    def over_time?(turn, agent)
      limit = agent.timeout or return false
      return false unless turn.started_at

      (Time.current - turn.started_at) > limit
    end
  end
end
