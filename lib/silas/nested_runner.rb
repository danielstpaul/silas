module Silas
  # Drives a nested subagent Session's turn to terminal INLINE (no AgentLoopJob),
  # inside the parent's delegate #call. Swaps the subagent's scope in as the
  # active globals for the duration, then restores — so the existing loop
  # machinery (StepRunner/Instructions/Budget/Ledger) runs unchanged against the
  # subagent's tools/instructions. Synchronous, depth-1 (v1).
  #
  # Durability of the nested run = its persisted rows; its exactly-once BOUNDARY
  # is the parent's at_most_once delegate invocation (a crash parks it in-doubt).
  module NestedRunner
    module_function

    def run(session, input:)
      scope = Silas.subagent_scope(session.agent_name)
      turn = session.turns.create!(index: 0, input: input)

      Silas.with_agent_scope(scope) do
        agent = scope.agent
        turn.update!(status: "running", started_at: Time.current)
        Instructions.snapshot!(turn) # renders the SUBAGENT's instructions + snapshots ITS digest

        index = 0
        loop do
          case StepRunner.call(turn, index)
          when :parked   then return turn.finish!(:failed, reason: "subagent_parked") && turn.reload
          when :terminal then return turn.finish!(:completed) && turn.reload
          end
          if (reason = Budget.exceeded_reason(turn, agent: agent))
            return turn.finish!(:failed, reason: reason) && turn.reload
          end

          index += 1
          if index >= agent.max_steps
            turn.finish!(:failed, reason: "max_steps")
            return turn.reload
          end
        end
      end
    end
  end
end
