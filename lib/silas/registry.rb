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
      Silas.config.named_agent_scopes = -> { registry.named_agent_scopes }
      Silas.config.agent_override = nil
      Silas.config.instructions_dir = nil
      Silas.reset_agent_memo!
      # Boot is the last place a bad channel route can fail safely. Directory
      # names, not built scopes: validation must not force every named agent's
      # tools to constantize before anything needs them.
      Silas::Channel.validate_routes!(registry.named_agent_dirs.map { |dir| File.basename(dir) })
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
      @schedules ||= (
        Dir[@root.join("app/agent/schedules/**/*.{md,rb}")].sort +
        Dir[@root.join("app/agents/*/schedules/**/*.{md,rb}")].sort
      ).map { |f| Schedule.parse(Pathname(f), root: @root) }
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
      b["ask_question"] = Silas::Tools::AskQuestion if Silas.config.ask_question
      b["load_skill"] = Silas::Tools::LoadSkill if skills.any?
      b["delegate"] = Silas::Tools::Delegate if subagent_dirs.any?
      b["run_code"] = Silas::Tools::RunCode if Silas.sandbox_enabled?
      if Silas.memory_enabled?
        b["remember"] = Silas::Tools::Remember
        b["recall"] = Silas::Tools::Recall
      end
      b["handoff"] = Silas::Tools::Handoff if named_agent_dirs.any?
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
    # schema (incl. the delegate roster + remote connection tools), skill
    # description, or final_answer schema changes.
    #
    # final_answer is appended ONLY when present: schema-less agents keep a
    # byte-identical digest across upgrades, so turns parked over a deploy
    # never fail NondeterminismError for a key they don't use.
    def digest
      payload = { tools: definitions, skills: skills.map { |s| [ s.name, s.description ] } }
      payload[:final_answer] = root_agent.final_answer if root_agent.final_answer.present?
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def root_agent
      @root_agent ||= Silas::Agent.load(root: @root)
    end

    # --- named agents (app/agents/<name>/ — the staff pattern) ---------------

    RESERVED_AGENT_NAMES = %w[agent shared].freeze

    def named_agent_dirs
      @named_agent_dirs ||= Dir[@root.join("app/agents/*")].select { |p| File.directory?(p) }.sort
    end

    # { "clerk" => AgentScope, ... }. Each named agent is a full top-level
    # agent: its own instructions.md, agent.yml, tools/, skills/ — autoloaded
    # under Agents::<Camelized>. Sessions stamped with the name run every turn
    # under this scope (loop-enforced, resume-safe, thread-isolated).
    def named_agent_scopes
      @named_agent_scopes ||= named_agent_dirs.to_h do |dir|
        name = File.basename(dir)
        if RESERVED_AGENT_NAMES.include?(name)
          raise Error, "app/agents/#{name} collides with a reserved name — " \
                       "'agent' is the root app/agent; rename the directory"
        end

        [ name, build_agent_scope(Pathname(dir), name, const_base: "Agents::#{name.camelize}",
                                                       run_code: Silas.sandbox_enabled?, named: true) ]
      end
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
      build_agent_scope(dir, name, const_base: "Agent::Subagents::#{name.camelize}",
                                   agent: subagent_agent(dir, name))
    end

    # Shared scope builder for subagents and named agents: tools by filename
    # identity under const_base, skills, the load_skill builtin when skills
    # exist, run_code when asked, and the scope's own digest (the same
    # NondeterminismError guard root turns get).
    #
    # A named agent is a full member of staff: it gets ask_question (parking to
    # ask a person is the premise, not a root-agent privilege) and the shared
    # remote connections. Connections live in the root app/agent/connections/ —
    # one set of credentials for the app, reachable by everyone. Subagents get
    # neither: they run inside a parent's turn, which is where the human contact
    # and the remote surface belong.
    def build_agent_scope(dir, name, const_base:, agent: nil, run_code: false, named: false)
      tools = Dir[dir.join("tools/*.rb")].sort.to_h do |file|
        tname = File.basename(file, ".rb")
        klass = "#{const_base}::Tools::#{tname.camelize}".constantize
        raise Error, "#{klass} must inherit from Silas::Tool" unless klass.ancestors.include?(Silas::Tool)

        klass.validate_signature!
        [ tname, klass ]
      end
      skills = Dir[dir.join("skills/*.md")].sort.map { |f| Skill.parse(f) }
      builtins = {}
      builtins["ask_question"] = Silas::Tools::AskQuestion if named && Silas.config.ask_question
      builtins["load_skill"] = Silas::Tools::LoadSkill if skills.any?
      builtins["run_code"] = Silas::Tools::RunCode if run_code
      if named && Silas.memory_enabled?
        builtins["remember"] = Silas::Tools::Remember
        builtins["recall"] = Silas::Tools::Recall
      end
      builtins["handoff"] = Silas::Tools::Handoff if named && named_agent_dirs.size > 1
      remote = connections if named
      resolver = lambda do |n|
        klass = tools[n] || builtins[n]
        return klass.new if klass

        remote&.resolve(n) or raise Error, "unknown tool #{n.inspect} for agent #{name.inspect}"
      end
      definitions = (tools.values + builtins.values).map(&:schema) + (remote&.definitions || [])
      loaded_agent = agent || Silas::Agent.load(dir: dir)
      payload = { tools: definitions, skills: skills.map { |s| [ s.name, s.description ] } }
      payload[:final_answer] = loaded_agent.final_answer if loaded_agent.final_answer.present?
      digest = Digest::SHA256.hexdigest(JSON.generate(payload))

      Silas::AgentScope.new(name: name, dir: dir, agent: loaded_agent,
                            resolver: resolver, definitions: definitions, digest: digest, skills: skills)
    end
  end
end
