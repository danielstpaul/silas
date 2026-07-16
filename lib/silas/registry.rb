require "digest"

module Silas
  # Discovery by directory convention — no registration. Globs app/agent/,
  # resolves tool classes through Zeitwerk, validates them at boot, and
  # computes the definitions digest that guards against a deploy changing the
  # agent mid-turn (NondeterminismError).
  class Registry
    def self.install!(root: Rails.root)
      registry = new(root: root)
      Silas.config.tool_resolver = registry.resolver
      Silas.config.tool_definitions = -> { registry.definitions }
      Silas.config.definitions_digest = -> { registry.digest }
      Silas.config.skills = -> { registry.skills }
      Silas.config.schedules = -> { registry.schedules }
      Silas.config.channel_resolver = ->(name) { registry.channels[name] }
      Silas.config.subagent_index = -> { registry.subagent_index }
      Silas.config.subagent_scopes = -> { registry.subagent_scopes }
      Silas.config.agent_override = nil
      Silas.config.instructions_dir = nil
      Silas.reset_agent_memo!
      registry
    end

    def initialize(root: Rails.root)
      @root = Pathname(root)
    end

    # tool_name => Class. Filename is identity; the class must match Zeitwerk's
    # expectation for it (Agent::Tools::<Camelized>).
    def tools
      @tools ||= Dir[@root.join("app/agent/tools/*.rb")].sort.to_h do |file|
        name = File.basename(file, ".rb")
        klass = "Agent::Tools::#{name.camelize}".constantize
        unless klass.ancestors.include?(Silas::Tool)
          raise Error, "#{klass} (from #{file}) must inherit from Silas::Tool"
        end

        klass.validate_signature!
        [ name, klass ]
      end
    end

    def skills
      @skills ||= Dir[@root.join("app/agent/skills/*.md")].sort.map { |f| Skill.parse(f) }
    end

    # Schedules by filesystem identity (subdirs included). Sorted so identity
    # and compile order are deterministic. Deliberately NOT in #definitions or
    # #digest — a schedule is a trigger, not a model-visible capability.
    def schedules
      @schedules ||= Dir[@root.join("app/agent/schedules/**/*.{md,rb}")].sort
                         .map { |f| Schedule.parse(Pathname(f), root: @root) }
    end

    # name => Channel subclass. Filename identity, like tools. Also not in the
    # digest — a channel is a trigger/transport, not a model-visible capability.
    def channels
      @channels ||= Dir[@root.join("app/agent/channels/*.rb")].sort.to_h do |file|
        name = File.basename(file, ".rb")
        klass = "Agent::Channels::#{name.camelize}".constantize
        raise Error, "#{klass} (from #{file}) must inherit from Silas::Channel" unless klass < Silas::Channel

        [ name, klass ]
      end
    end

    # Built-in harness tools: load_skill when skills exist; delegate when
    # subagents exist (root only — subagents never get delegate: depth-1).
    def builtins
      b = {}
      b["load_skill"] = Silas::Tools::LoadSkill if skills.any?
      b["delegate"] = Silas::Tools::Delegate if subagent_dirs.any?
      b["run_code"] = Silas::Tools::RunCode if Silas.sandbox_enabled?
      b
    end

    # Remote MCP tools from app/agent/connections/*.yml (warmed once at boot).
    def connections
      @connections ||= Silas::Connections.new(root: @root, client_factory: Silas.config.mcp_client_factory).warm!
    end

    def resolver
      lambda do |name|
        klass = tools[name] || builtins[name]
        return klass.new if klass

        connections.resolve(name) or raise Error, "unknown tool #{name.inspect}"
      end
    end

    def definitions
      (tools.values + builtins.values).map(&:schema) + connections.definitions
    end

    # Stable across boots for the same agent definition; changes when any tool
    # schema (incl. the delegate roster + remote connection tools), or skill
    # description, changes.
    def digest
      Digest::SHA256.hexdigest(JSON.generate({
        tools: definitions,
        skills: skills.map { |s| [ s.name, s.description ] }
      }))
    end

    # --- subagents -----------------------------------------------------------

    def subagent_dirs
      @subagent_dirs ||= Dir[@root.join("app/agent/subagents/*")].select { |p| File.directory?(p) }.sort
    end

    def subagent_index
      subagent_dirs.map do |dir|
        name = File.basename(dir)
        [ name, subagent_agent(dir, name).description ]
      end
    end

    def subagent_scopes
      @subagent_scopes ||= subagent_dirs.to_h do |dir|
        name = File.basename(dir)
        [ name, build_subagent_scope(Pathname(dir), name) ]
      end
    end

    private

    def subagent_agent(dir, name)
      agent = Silas::Agent.load(dir: dir)
      raise Error, "subagent #{name}: agent.yml must set `description`" if agent.description.blank?

      agent
    end

    def build_subagent_scope(dir, name)
      const_base = "Agent::Subagents::#{name.camelize}"
      tools = Dir[dir.join("tools/*.rb")].sort.to_h do |file|
        tname = File.basename(file, ".rb")
        klass = "#{const_base}::Tools::#{tname.camelize}".constantize
        raise Error, "#{klass} must inherit from Silas::Tool" unless klass.ancestors.include?(Silas::Tool)

        klass.validate_signature!
        [ tname, klass ]
      end
      skills = Dir[dir.join("skills/*.md")].sort.map { |f| Skill.parse(f) }
      builtins = skills.any? ? { "load_skill" => Silas::Tools::LoadSkill } : {}
      resolver = ->(n) { (tools[n] || builtins.fetch(n)).new }
      definitions = (tools.values + builtins.values).map(&:schema)
      digest = Digest::SHA256.hexdigest(JSON.generate(tools: definitions, skills: skills.map { |s| [ s.name, s.description ] }))

      Silas::AgentScope.new(name: name, dir: dir, agent: subagent_agent(dir, name),
                            resolver: resolver, definitions: definitions, digest: digest, skills: skills)
    end
  end
end
