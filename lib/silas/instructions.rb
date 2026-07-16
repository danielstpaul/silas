require "erb"

module Silas
  # Renders instructions.md ONCE per turn into an immutable snapshot — the
  # determinism anchor. (Skill-index injection and loaded-skill inlining land
  # with the skills work; the snapshot-once mechanics are load-bearing now.)
  module Instructions
    module_function

    def snapshot!(turn)
      return if turn.instructions_snapshot.present? # idempotent: replay-safe

      turn.update!(
        instructions_snapshot: render(turn),
        definitions_digest: Silas.config.definitions_digest&.call.to_s
      )
    end

    def render(turn)
      [ base_instructions(turn), skill_index_block(turn.session), loaded_skills_block(turn.session) ]
        .compact.join("\n\n")
    end

    def base_instructions(turn)
      # config.instructions_dir points at the active agent's directory (root or a
      # subagent, swapped during a nested run).
      dir = Silas.config.instructions_dir || Rails.root.join("app/agent")
      path = Pathname(dir).join("instructions.md")
      return default_instructions unless path.exist?

      ERB.new(path.read).result_with_hash(session: turn.session, agent_name: turn.session.agent_name)
    end

    # Advertise skill descriptions (eve's routing hint); bodies load on demand.
    def skill_index_block(session)
      advertised = Silas.skills.reject { |s| session.loaded_skills.include?(s.name) }
      return nil if advertised.empty?

      lines = advertised.map { |s| "- #{s.name}: #{s.description}" }
      "## Available skills\n\nLoad with the load_skill tool when relevant:\n#{lines.join("\n")}"
    end

    # Skills loaded in prior turns are inlined "for the rest of the session".
    def loaded_skills_block(session)
      loaded = Silas.skills.select { |s| session.loaded_skills.include?(s.name) }
      return nil if loaded.empty?

      loaded.map { |s| "## Skill: #{s.name}\n\n#{s.body.strip}" }.join("\n\n")
    end

    def default_instructions
      "You are a helpful agent."
    end
  end
end
