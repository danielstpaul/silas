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
        definitions_digest: Silas.definitions_digest.to_s
      )
    end

    def render(turn)
      [ base_instructions(turn), memory_block(turn.session), skill_index_block(turn.session), loaded_skills_block(turn.session) ]
        .compact.join("\n\n")
    end

    def base_instructions(turn)
      # config.instructions_dir points at the active agent's directory (root or a
      # subagent, swapped during a nested run).
      dir = Silas.instructions_dir || Rails.root.join("app/agent")
      path = Pathname(dir).join("instructions.md")
      return default_instructions unless path.exist?

      ERB.new(path.read).result_with_hash(session: turn.session, agent_name: turn.session.agent_name)
    end

    # Recent memories surface into the snapshot (bounded; recall digs deeper).
    def memory_block(session)
      return nil unless Silas.memory_enabled?

      memories = Silas::Memory.recall(agent_name: session.agent_name,
                                      limit: Silas.config.memory_injection_limit)
      return nil if memories.empty?

      "## Memory (most recent — use the recall tool for more)\n\n" +
        memories.map { |m| "- #{m.to_line}" }.join("\n")
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
