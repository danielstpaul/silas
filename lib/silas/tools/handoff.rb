module Silas
  module Tools
    # Staff-to-staff composition WITHOUT free-form agent chatter: file a brief
    # that starts (or awaits) another named agent's session, linked to this one.
    # at_most_once! — the handoff is one external effect; a crash parks it
    # in-doubt instead of double-starting the colleague.
    class Handoff < Tool
      class << self
        # Roster from DIRECTORY NAMES only — reading scopes here would recurse
        # (description -> digest -> scope build -> description). Names alone
        # keep the digest roster-sensitive without the cycle.
        def description
          names = Dir[Rails.root.join("app/agents/*")].select { |p| File.directory?(p) }
                     .map { |p| File.basename(p) }.sort
          "Hand a task to another staff agent as a self-contained brief (they share none of " \
          "your context). Async by default; await: true waits for their answer. " \
          "Staff: #{names.join(', ')}."
        end
      end

      param :agent, :string, desc: "Which staff agent takes this."
      param :brief, :string, desc: "Fully self-contained task brief."
      param :await, :boolean, desc: "true = run now and return their answer; default fire-and-forget."

      at_most_once!

      MAX_CHAIN = 3

      def call(agent:, brief:, await: nil)
        target = agent.to_s
        return { "error" => "unknown agent #{target.inspect}" } unless Silas.named_agent?(target)
        return { "error" => "an agent cannot hand off to itself" } if target == session.agent_name

        chain = ancestry(session)
        if chain.include?(target)
          return { "error" => "handoff cycle: #{[ *chain.reverse, session.agent_name, target ].join(' -> ')}" }
        end
        return { "error" => "handoff chain too deep (max #{MAX_CHAIN})" } if chain.size >= MAX_CHAIN

        nested = Session.create!(agent_name: target, parent_session_id: session.id,
                                 metadata: { "handoff_from" => session.agent_name })
        if await
          # Inline drive via NestedRunner (NOT AgentLoopJob.perform_now: a
          # Continuable job's isolated steps re-enqueue and return early under
          # production isolate_steps — the await would see a half-run turn).
          turn = NestedRunner.run(nested, input: brief, scope: Silas.named_agent_scope!(target))
          { "session_id" => nested.id, "status" => turn.status, "answer" => turn.answer_text.to_s }
        else
          turn = nested.continue(input: brief, enqueue: false)
          AgentLoopJob.perform_later(turn.id)
          { "session_id" => nested.id, "status" => "queued" }
        end
      end

      private

      def ancestry(session)
        names = []
        cursor = session
        while cursor.parent_session_id && names.size <= MAX_CHAIN
          cursor = Session.find_by(id: cursor.parent_session_id) or break
          names << cursor.agent_name
        end
        names
      end
    end
  end
end
