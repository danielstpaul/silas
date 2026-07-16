module Silas
  module Inbox
    # cost_microcents is declared on silas_turns but never populated (only
    # silas_steps carry real token counts). So the inbox derives cost at read
    # time from step tokens x a host-supplied price map — and honestly reports
    # `unpriced` when a model isn't in the map rather than a lying £0.00.
    module Cost
      module_function

      def for_session(session)
        rows = Silas::Step.joins(:turn)
                          .where(silas_turns: { session_id: session.id })
                          .group(:model)
                          .pluck(:model, Arel.sql("SUM(silas_steps.input_tokens)"), Arel.sql("SUM(silas_steps.output_tokens)"))
        aggregate(rows)
      end

      def for_turn(turn)
        rows = Silas::Step.where(turn_id: turn.id)
                          .group(:model)
                          .pluck(:model, Arel.sql("SUM(silas_steps.input_tokens)"), Arel.sql("SUM(silas_steps.output_tokens)"))
        aggregate(rows)
      end

      def for_agent(agent_name)
        rows = Silas::Step.joins(turn: :session)
                          .where(silas_sessions: { agent_name: agent_name })
                          .group(:model)
                          .pluck(:model, Arel.sql("SUM(silas_steps.input_tokens)"), Arel.sql("SUM(silas_steps.output_tokens)"))
        aggregate(rows)
      end

      def aggregate(rows)
        input = output = microcents = 0
        unpriced = false
        rows.each do |model, in_tok, out_tok|
          in_tok = in_tok.to_i
          out_tok = out_tok.to_i
          input += in_tok
          output += out_tok
          if (price = Silas.config.model_prices[model])
            microcents += (in_tok * price[:in] + out_tok * price[:out]) / 1000
          else
            unpriced = true
          end
        end
        { input_tokens: input, output_tokens: output, microcents: microcents, unpriced: unpriced }
      end

      # microcents -> "$0.0123" (or nil when unpriced with no priced tokens)
      def format(cents)
        return nil if cents.nil?

        "$%.4f" % (cents / 1_000_000.0)
      end
    end
  end
end
