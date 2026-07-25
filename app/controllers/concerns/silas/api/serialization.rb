module Silas
  module Api
    # Minimal, dependency-free JSON shapes. Deliberately explicit allowlists —
    # never as_json a whole row (instruction snapshots and internal columns
    # don't belong on the wire).
    module Serialization
      def session_json(session, include_turns: true, trace: false)
        base = {
          id: session.id, agent_name: session.agent_name,
          channel: session.channel, status: session.status,
          parent_session_id: session.parent_session_id,
          child_session_ids: session.child_sessions.ids,
          cost: Silas::Inbox::Cost.for_session(session),
          created_at: session.created_at, updated_at: session.updated_at
        }
        return base unless include_turns

        base.merge(turns: session.turns.map { |t| turn_json(t, trace: trace) })
      end

      def turn_json(turn, trace: false)
        base = {
          id: turn.id, session_id: turn.session_id, index: turn.index,
          status: turn.status, input: turn.input,
          failure_reason: turn.failure_reason,
          answer_text: (turn.answer_text if turn.completed?),
          answer_data: (turn.answer_data if turn.completed?),
          created_at: turn.created_at, updated_at: turn.updated_at
        }
        return base unless trace

        base.merge(steps: turn.steps.map do |step|
          step_json(step).merge(invocations: step.tool_invocations.map { |i| invocation_json(i) })
        end)
      end

      def step_json(step)
        {
          id: step.id, turn_id: step.turn_id, index: step.index,
          status: step.status, terminal: step.terminal,
          model: step.model, provider: step.provider,
          text: Array(step.response_blocks).select { |b| b["type"] == "text" }
                                           .map { |b| b["text"] }.join.presence,
          structured: Array(step.response_blocks).reverse
                                                 .find { |b| b["type"] == "structured" }&.dig("data"),
          updated_at: step.updated_at
        }
      end

      def invocation_json(invocation)
        {
          id: invocation.id, turn_id: invocation.turn_id,
          tool_name: invocation.tool_name, status: invocation.status,
          approval_state: invocation.approval_state,
          arguments: invocation.arguments, result: invocation.result,
          error: invocation.error, approved_by: invocation.approved_by,
          decline_reason: invocation.decline_reason,
          updated_at: invocation.updated_at
        }
      end
    end
  end
end
