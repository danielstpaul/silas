module Silas
  # Keeps long sessions under the model's context window by summarising prior
  # turns into a Compaction row — the alternative today is the provider
  # rejecting the prompt and the turn failing.
  #
  # The design constraint comes from MessageBuilder: replayed executions must
  # produce byte-identical message arrays, so a summary can never be computed
  # at build time. Compaction is therefore an EFFECT, made exactly-once the
  # same way tool effects are:
  #
  #   - ensure! runs at the top of each step, INSIDE the isolated continuation
  #     step. A crash anywhere re-runs the whole step, and the unique index on
  #     (session_id, up_to_turn_index) makes the claim idempotent.
  #   - The summary model call happens once; the row it completes is what
  #     MessageBuilder reads from then on. A crash mid-summary leaves a
  #     pending row; the re-run summarises again and completes it — no step
  #     ever executed against the lost draft.
  #   - The boundary is fixed for the whole turn (all PRIOR turns, 0..index-1),
  #     so a re-executed step finds the same row a crashed attempt created:
  #     same rows in, same messages out.
  #
  # What it deliberately does not do (v1): compact within the current turn —
  # a single turn's growth is bounded by max_steps, while a session's turn
  # count is unbounded, and mid-turn boundaries would cut between a tool_use
  # and its result. If the current turn alone outgrows the window, that is
  # max_steps' problem, not compaction's.
  module Compactor
    module_function

    SUMMARY_SYSTEM = <<~PROMPT.freeze
      You are compacting the earlier part of a long conversation so it can
      continue within the model's context window. Write a dense summary that
      preserves everything a future turn might rely on: facts and figures,
      decisions made, tool calls and their results (ids, amounts, names),
      commitments given to the user, and anything explicitly left open.
      Write it as plain prose. Do not add commentary about the summarisation
      itself.
    PROMPT

    # Per-block caps keep the summarisation call itself well under the window.
    TOOL_RESULT_CHARS = 2_000
    TEXT_CHARS = 4_000

    # Called before each step's model call. Returns the applicable completed
    # Compaction (or nil), creating it first when the context has outgrown the
    # threshold.
    def ensure!(turn)
      threshold = threshold_for(turn)
      return Compaction.latest_for(turn) if threshold.nil? # feature off: existing rows still apply
      return nil if turn.index.zero?                       # no prior turns to compact

      boundary = turn.index - 1
      if (existing = Compaction.find_by(session_id: turn.session_id, up_to_turn_index: boundary))
        # Pending = a crash mid-summary. The trigger decision was already made
        # and no step ever ran against the lost draft, so finish the claimed
        # work rather than re-litigating the threshold.
        summarise!(turn, existing) unless existing.completed?
        return Compaction.latest_for(turn)
      end

      measured = measured_context(turn)
      return Compaction.latest_for(turn) if measured.nil? || measured < threshold

      row = claim!(turn, boundary, measured)
      summarise!(turn, row) if row # nil: a racer claimed AND completed it
      Compaction.latest_for(turn)
    end

    # The provider's own measure of the prompt: the last completed step's
    # input_tokens IS the context size of the previous model call. Persisted,
    # so a replayed trigger decision reads the same number.
    def measured_context(turn)
      Step.joins(:turn)
          .where(silas_turns: { session_id: turn.session_id })
          .where.not(input_tokens: nil)
          .order(id: :desc).limit(1).pick(:input_tokens)
    end

    # config.compact_at: a Float in (0, 1] is a fraction of the model's
    # registry context window (unknown window => off); an Integer is an
    # absolute token threshold (works with any adapter — custom engines and
    # the chaos harness have no registry entry). nil/false disables.
    def threshold_for(turn)
      setting = Silas.config.compact_at
      return nil unless setting
      return setting if setting.is_a?(Integer)

      window = context_window_for(StepRunner.turn_model(turn))
      window && (window * setting.to_f).to_i
    end

    def context_window_for(model)
      ::RubyLLM.models.find(model).context_window
    rescue StandardError
      nil
    end

    def claim!(turn, boundary, measured)
      Compaction.create!(
        session_id: turn.session_id,
        up_to_turn: Turn.find_by!(session_id: turn.session_id, index: boundary),
        up_to_turn_index: boundary,
        status: "pending",
        tokens_before: measured
      )
    rescue ActiveRecord::RecordNotUnique
      # A racing execution claimed it. Pending -> finish their summary work;
      # completed -> nothing to do (nil tells the caller to just read).
      row = Compaction.find_by!(session_id: turn.session_id, up_to_turn_index: boundary)
      row.completed? ? nil : row
    end

    def summarise!(turn, row)
      model = StepRunner.turn_model(turn)
      Silas.instrument(:compact, session_id: turn.session_id, turn_id: turn.id,
                                 up_to_turn_index: row.up_to_turn_index,
                                 tokens_before: row.tokens_before, model: model) do |payload|
        context = {
          turn: turn, index: nil, compaction: true,
          system: SUMMARY_SYSTEM,
          messages: [ { role: "user", content: transcript_for(turn, row) } ],
          tools: [], model: model, final_answer: nil, limits: {}
        }

        engine = Silas.resolved_adapter
        result =
          if (hook = Silas.config.around_model_call)
            hook.call(context) { engine.execute_step(context) }
          else
            engine.execute_step(context)
          end

        summary = result.blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
        row.update!(status: "completed", summary: summary, model: model,
                    input_tokens: result.usage&.dig(:input_tokens),
                    output_tokens: result.usage&.dig(:output_tokens))
        payload[:input_tokens] = row.input_tokens
        payload[:output_tokens] = row.output_tokens
      end
    end

    # The span rendered as a plain-text transcript — one user message into the
    # summary call. Recursive by construction: a previous summary opens the
    # transcript, so each compaction folds the last one in.
    def transcript_for(turn, row)
      parts = []
      previous = Compaction.completed
                           .where(session_id: turn.session_id)
                           .where(up_to_turn_index: ...row.up_to_turn_index)
                           .order(:up_to_turn_index).last
      parts << "Earlier conversation, already summarised:\n#{previous.summary}" if previous

      floor = previous ? previous.up_to_turn_index : -1
      Turn.where(session_id: turn.session_id, index: (floor + 1)..row.up_to_turn_index)
          .order(:index).each do |prior|
        parts << "User: #{prior.input}"
        Step.where(turn_id: prior.id).order(:index).select(&:completed?).each do |step|
          parts.concat(step_lines(step))
        end
      end
      parts.join("\n\n")
    end

    def step_lines(step)
      lines = Array(step.response_blocks).filter_map do |b|
        case b["type"]
        when "text"       then "Assistant: #{b['text'].to_s.truncate(TEXT_CHARS)}"
        when "structured" then "Assistant (structured answer): #{JSON.generate(b['data'])}"
        end
      end
      ToolInvocation.where(step_id: step.id).order(:id).each do |inv|
        lines << "Assistant called #{inv.tool_name}(#{JSON.generate(inv.arguments || {})}) " \
                 "-> #{JSON.generate(inv.result || inv.status).truncate(TOOL_RESULT_CHARS)}"
      end
      lines
    end
  end
end
