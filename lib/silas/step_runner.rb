module Silas
  # The idempotent body of one continuation step: at most one model call per
  # (turn, index), replay feeds from rows, tool execution goes through the
  # Ledger. Every path must be safe to run twice (crash replay) and safe to
  # run in a fresh job (post-approval resume).
  module StepRunner
    module_function

    # Returns :continue, :terminal, or :parked.
    def call(turn, index)
      step = Step.find_or_create_by!(turn: turn, index: index)

      unless step.completed?
        result = execute_model_call(turn, index, step)

        # One transaction: the step's response, its terminal verdict, and the
        # pending ledger rows commit together — or none of them do.
        ApplicationRecord.transaction do
          step.update!(
            status: "completed",
            response_blocks: result.blocks,
            stop_reason: result.stop_reason,
            terminal: result.terminal?,
            model: turn_model(turn),
            provider: provider_for(turn_model(turn)),
            input_tokens: result.usage&.dig(:input_tokens),
            output_tokens: result.usage&.dig(:output_tokens)
          )
          result.tool_calls.each do |tc|
            ToolInvocation.create!(
              step: step, turn: turn,
              tool_call_id: tc.id, tool_name: tc.name, arguments: tc.arguments,
              effect_mode: effect_mode_for(tc.name)
            )
          end
        rescue ActiveRecord::RecordNotUnique
          # A racing execution committed this step first; fall through to
          # settle from the persisted rows.
        end
        step.reload
      end

      case Ledger.settle!(step, resolver: Silas.tool_resolver)
      when :parked
        park_turn!(turn, step)
        :parked
      else
        step.terminal? ? :terminal : :continue
      end
    end

    def execute_model_call(turn, index, step)
      assert_definitions_unchanged!(turn)
      engine = Silas.resolved_adapter
      context = {
        turn: turn,
        index: index,
        system: turn.instructions_snapshot,
        messages: MessageBuilder.call(turn, upto_index: index),
        tools: Silas.tool_definitions,
        model: turn_model(turn),
        final_answer: Silas.agent.final_answer,
        limits: { max_steps: Silas.agent.max_steps }
      }

      # Live deltas: the engine yields Events, the buffer coalesces them into
      # "delta.silas" notifications. A replayed step never reaches this method
      # (the completed? guard above), so replay emits nothing. The emitter is
      # created HERE and closed over by the inner block, so around_model_call
      # hooks keep their existing one-argument contract and can't swallow it.
      buffer = DeltaBuffer.new(turn: turn, step: step)
      emitter = ->(event) { buffer.append(event.payload[:text].to_s) if event.type == :text_delta }

      begin
        if (hook = Silas.config.around_model_call)
          hook.call(context) { engine.execute_step(context, &emitter) }
        else
          engine.execute_step(context, &emitter)
        end
      ensure
        # Tail flush BEFORE the step row commits — the authoritative
        # after_commit render must never race a straggling delta batch.
        buffer.finish
      end
    end

    # A deploy that changes tools/skills mid-turn must fail loudly, never
    # resume into a different agent than the one that started the turn.
    def assert_definitions_unchanged!(turn)
      return if turn.definitions_digest.blank? || Silas.definitions_digest.nil?

      live = Silas.definitions_digest.to_s
      return if live == turn.definitions_digest

      turn.finish!(:failed, reason: "definitions_changed")
      Silas.instrument(:nondeterminism, turn_id: turn.id,
                                        was: turn.definitions_digest.to_s[0, 12],
                                        now: live[0, 12])
      raise NondeterminismError,
            "Tool/skill definitions changed mid-turn (digest #{turn.definitions_digest[0, 12]}… → " \
            "#{live[0, 12]}…). The turn was failed rather than resumed against a different agent."
    end

    def park_turn!(turn, step)
      new_status = step.tool_invocations.reload.any?(&:in_doubt?) ? "in_doubt" : "waiting"
      turn.update!(status: new_status)
    end

    def effect_mode_for(tool_name)
      tool = Silas.tool_resolver.call(tool_name)
      tool.respond_to?(:effect_mode) ? tool.effect_mode.to_s : "at_most_once"
    end

    def turn_model(_turn)
      Silas.agent.model
    end

    # The provider RubyLLM's own resolution picks for this model id, stamped
    # on the row so cost lookups price against (model, provider) forever
    # after — the registry's tie-break can change; the row shouldn't. nil for
    # ids the installed registry doesn't know (fakes, custom engines).
    def provider_for(model)
      ::RubyLLM.models.find(model).provider
    rescue StandardError
      nil
    end
  end
end
