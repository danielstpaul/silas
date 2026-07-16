module Silas
  # The engine-owned analog of StepRunner: it wraps one whole subprocess run in
  # a single anchor Step and persists the durable result. Replay-aware and
  # fail-closed — a resumed run whose subprocess got far enough to register a
  # CLI session but did not finish is FAILED rather than re-spawned, because an
  # engine-owned subprocess can't be replayed exactly-once (design risk #1).
  module SubprocessRunner
    module_function

    # Returns :terminal or :failed.
    def call(turn)
      step = Step.find_or_create_by!(turn: turn, index: 0)
      return :terminal if step.completed?

      if turn.cli_session_id.present?
        # A prior execution spawned a subprocess that never completed the step.
        turn.finish!(:failed, reason: "agent_sdk_interrupted")
        return :failed
      end

      result = Silas.resolved_engine.execute_step(engine_context(turn, step))
      step.update!(
        status: "completed", terminal: true,
        response_blocks: result.blocks, stop_reason: result.stop_reason,
        model: Silas.agent.model,
        input_tokens: result.usage&.dig(:input_tokens),
        output_tokens: result.usage&.dig(:output_tokens)
      )
      :terminal
    end

    def engine_context(turn, step)
      { turn: turn, step: step, index: 0,
        system: turn.instructions_snapshot,
        messages: MessageBuilder.call(turn, upto_index: nil),
        tools: Silas.tool_definitions,
        model: Silas.agent.model,
        limits: { max_steps: Silas.agent.max_steps } }
    end
  end
end
