module Silas
  module Tools
    # The built-in progressive-disclosure tool (eve's mechanism): skill
    # descriptions are advertised in the instructions; the body loads on
    # demand and — because the body IS the tool result — rides the ledger and
    # replays byte-identically for free. Loading also registers the skill on
    # the session so subsequent turns inline it directly.
    class LoadSkill < Tool
      description "Load the full playbook for a named skill. Use when a task matches a skill description."
      transactional!

      def self.tool_name = "load_skill"

      def call(name:)
        skill = Silas.skills.find { |s| s.name == name }
        return { "error" => "unknown skill #{name.inspect}" } unless skill

        unless session.loaded_skills.include?(name)
          session.update!(loaded_skills: session.loaded_skills + [ name ])
        end
        { "skill" => name, "content" => skill.body }
      end
    end
  end
end
