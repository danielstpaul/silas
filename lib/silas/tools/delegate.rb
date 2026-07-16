module Silas
  module Tools
    # Built-in. Added to the ROOT toolset only when subagents exist; NOT given to
    # subagents (depth-1, no recursion). The whole delegation is ONE external
    # effect: at_most_once! means a crash mid-run parks the parent invocation
    # in-doubt (the exactly-once boundary), never silently re-runs.
    class Delegate < Silas::Tool
      at_most_once!
      approval :never
      param :subagent, :string, desc: "Which subagent to run (one of the names listed above)."
      param :input, :string, desc: "Full, self-contained task — the subagent shares NONE of your context."

      def self.tool_name = "delegate"

      # Dynamic description enumerates the roster, so the roster lands in the ROOT
      # digest (schema -> Registry#definitions -> digest). Adding a subagent
      # mid-turn => NondeterminismError, exactly like a skill change.
      def self.description
        roster = Silas.subagent_index
        base = "Delegate a self-contained subtask to a specialized subagent that runs with its own " \
               "instructions, tools, and a fresh context, then returns its final answer."
        return base if roster.empty?

        base + "\n\nAvailable subagents:\n" + roster.map { |n, d| "- #{n}: #{d}" }.join("\n")
      end

      # `session` is the PARENT session, set by the Ledger before #call.
      def call(subagent:, input:)
        return { "error" => "unknown subagent #{subagent.inspect}" } unless Silas.subagent?(subagent)

        nested = Silas::Session.create!(agent_name: subagent, parent_session_id: session.id,
                                        metadata: { "delegated_from" => session.id })
        turn = Silas::NestedRunner.run(nested, input: input)
        if turn.completed?
          { "session_id" => nested.id, "answer" => turn.answer_text }
        else
          { "session_id" => nested.id, "error" => "subagent did not finish (#{turn.status}: #{turn.failure_reason})" }
        end
      end
    end
  end
end
