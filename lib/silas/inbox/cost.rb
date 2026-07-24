module Silas
  module Inbox
    # Cost is derived at read time from step tokens. Prices come from
    # config.model_prices (the OVERRIDE map — custom deployments, fine-tunes,
    # models newer than the installed registry) and fall back to RubyLLM's
    # model registry, priced per (model, provider) — 85/1081 registry ids
    # exist under multiple providers at different prices, which is why steps
    # stamp the provider. Unknown stays `unpriced`, never a lying $0.00.
    module Cost
      module_function

      def for_session(session)
        rows = Silas::Step.joins(:turn)
                          .where(silas_turns: { session_id: session.id })
                          .group(:model, :provider)
                          .pluck(:model, :provider, Arel.sql("SUM(silas_steps.input_tokens)"), Arel.sql("SUM(silas_steps.output_tokens)"))
        aggregate(rows)
      end

      def for_turn(turn)
        rows = Silas::Step.where(turn_id: turn.id)
                          .group(:model, :provider)
                          .pluck(:model, :provider, Arel.sql("SUM(silas_steps.input_tokens)"), Arel.sql("SUM(silas_steps.output_tokens)"))
        aggregate(rows)
      end

      def for_agent(agent_name)
        rows = Silas::Step.joins(turn: :session)
                          .where(silas_sessions: { agent_name: agent_name })
                          .group(:model, :provider)
                          .pluck(:model, :provider, Arel.sql("SUM(silas_steps.input_tokens)"), Arel.sql("SUM(silas_steps.output_tokens)"))
        aggregate(rows)
      end

      def aggregate(rows)
        input = output = microcents = 0
        unpriced = false
        rows.each do |model, provider, in_tok, out_tok|
          in_tok = in_tok.to_i
          out_tok = out_tok.to_i
          input += in_tok
          output += out_tok
          if (rate = rate_for(model, provider))
            microcents += (in_tok * rate[:in] + out_tok * rate[:out]) / 1000
          else
            unpriced = true
          end
        end
        { input_tokens: input, output_tokens: output, microcents: microcents, unpriced: unpriced }
      end

      # {in:, out:} in cost-units per 1k tokens (1e6 units = $1), or nil when
      # the model can't be priced. Override map first; then the registry —
      # two-arg find when the step stamped a provider (the bare form
      # tie-breaks by a hardcoded preference list and can price the wrong
      # provider), registry $/MTok converted at x1000. A model with no price
      # data returns nil: unknown is never zero.
      def rate_for(model, provider)
        if (price = Silas.config.model_prices[model])
          return price
        end
        return nil if model.nil?

        info = provider.present? ? ::RubyLLM.models.find(model, provider) : ::RubyLLM.models.find(model)
        in_pm = info.input_price_per_million
        out_pm = info.output_price_per_million
        return nil unless in_pm && out_pm

        { in: (in_pm * 1000).round, out: (out_pm * 1000).round }
      rescue StandardError
        nil
      end

      # microcents -> "$0.0123" (or nil when unpriced with no priced tokens)
      def format(cents)
        return nil if cents.nil?

        "$%.4f" % (cents / 1_000_000.0)
      end
    end
  end
end
