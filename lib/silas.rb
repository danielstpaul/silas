# Active Job (Continuations) and Active Record are the chassis — load them
# even in --minimal host apps that skipped the railties.
require "active_job/railtie" if defined?(::Rails::Railtie)
require "active_record/railtie" if defined?(::Rails::Railtie)

require "silas/version"
require "silas/deprecator"
require "silas/instrumentation"
require "silas/errors"
require "silas/configuration"
require "silas/ledger"
require "silas/tool"
require "silas/skill"
require "silas/schedule"
require "silas/schedule/compiler"
require "silas/agent_scope"
require "silas/named_agent"
require "silas/tools/delegate"
require "silas/nested_runner"
require "silas/sandbox"
require "silas/tools/run_code"
require "silas/channel"
require "silas/slack"
require "silas/mcp/client"
require "silas/connection"
require "silas/connections"
require "silas/inbox"
require "silas/inbox/cost"
require "silas/inbox/delta_broadcaster"
require "silas/delta_buffer"
require "silas/budget"
require "silas/registry"
require "silas/agent"
require "silas/tools/load_skill"
require "silas/tools/remember"
require "silas/tools/recall"
require "silas/tools/handoff"
require "silas/mcp/handler"
require "silas/mcp/server"
require "silas/adapters/base"
require "ruby_llm"
require "silas/adapters/ruby_llm"
require "silas/message_builder"
require "silas/instructions"
require "silas/step_runner"
require "silas/eval" # after adapters (ScriptedEngine < Adapters::Base)
require "silas/chat"
require "silas/doctor"
require "silas/log_subscriber" if defined?(::ActiveSupport::LogSubscriber)

module Silas
  class << self
    def config
      @config ||= Configuration.new
    end

    # Reconfiguring re-resolves the engine and sandbox. Without this the
    # memos below outlive the config that produced them: a second
    # `Silas.configure { |c| c.engine = ... }` in one process kept serving the
    # FIRST engine. That silently broke multi-scenario `silas:eval` runs —
    # every scenario after the first ran the first one's script and still
    # reported pass/fail as if it hadn't. Re-resolution is cheap (one `.new`).
    def configure
      yield config
      config.validate!
      @resolved_adapter = nil
      @resolved_sandbox = nil
      config
    end

    def reset_configuration! # for specs
      @config = nil
      @resolved_adapter = nil
      @resolved_sandbox = nil
      @agent = nil
    end

    # A configured-but-disabled backend (e.g. Hermetic.null) must not register
    # run_code, so the object's own enabled? is the final word.
    def sandbox_enabled?
      return false if [ :none, nil ].include?(config.sandbox)

      resolved_sandbox.enabled?
    end

    def resolved_sandbox
      @resolved_sandbox ||=
        case config.sandbox
        when :none, nil then Sandbox::Null.new
        when :docker
          Sandbox::Docker.new(image: config.sandbox_image, network: config.sandbox_network,
                              memory: config.sandbox_memory, cpus: config.sandbox_cpus,
                              pids: config.sandbox_pids, workdir: config.sandbox_workdir,
                              docker_bin: config.sandbox_docker_bin)
        when Symbol then raise Error, "unknown sandbox #{config.sandbox.inspect}"
        else
          # A hermetic backend drops straight in (its Result is a superset of
          # ours). Auto-arm its ledger guard so a sandbox exec inside a ledger
          # transaction fails loud — same posture as our own Docker adapter.
          if defined?(Hermetic::Backends::Base) && config.sandbox.is_a?(Hermetic::Backends::Base)
            require "hermetic/silas"
          end
          config.sandbox
        end
    end

    def reset_agent_memo! = (@agent = nil) # after Registry.install! swaps dirs

    # The inference adapter instance. config.adapter may be :ruby_llm or any
    # object responding to #execute_step (specs, custom).
    def resolved_adapter
      @resolved_adapter ||=
        case config.adapter
        when :ruby_llm then Adapters::RubyLLM.new
        when :agent_sdk
          raise Error, "the :agent_sdk adapter was removed in Silas 0.2 — the claude -p " \
                       "subprocess integration is gone (its subscription-auth rationale was " \
                       "unreachable). Use adapter :ruby_llm, the production path."
        when Symbol then raise Error, "unknown adapter #{config.adapter.inspect}"
        else config.adapter
        end
    end

    # Renamed in 0.4: "engine" meant two unrelated things (the Rails engine at
    # Silas::Engine, and the inference backend), which is exactly the collision
    # ActiveJob avoids with QueueAdapters. Removed in 2.0.
    def resolved_engine
      Silas.deprecator.warn("Silas.resolved_engine is deprecated; use Silas.resolved_adapter")
      resolved_adapter
    end

    # ---- scope-aware readers -------------------------------------------------
    # Every reader consults the active AgentScope first (named agent or
    # subagent), falling back to the boot-time config the Registry installed.
    # The scope lives in IsolatedExecutionState — per-thread AND per-fiber
    # (Falcon-safe), so concurrent jobs running different agents in one
    # process can never see each other's tools.

    def tool_resolver
      current_scope&.resolver ||
        config.tool_resolver or raise Error, "no tool resolver configured (Registry boots one; specs must inject)"
    end

    def tool_definitions
      current_scope&.definitions || config.tool_definitions&.call || []
    end

    def skills
      current_scope&.skills || config.skills&.call || []
    end

    def schedules
      config.schedules&.call || []
    end

    # The live definitions digest as a String (nil when none configured).
    def definitions_digest
      current_scope&.digest || config.definitions_digest&.call&.to_s.presence
    end

    def instructions_dir
      current_scope&.dir || config.instructions_dir
    end

    # The active agent definition — or, given a name, a handle for a NAMED
    # agent (app/agents/<name>/) whose sessions run under that agent's scope:
    #
    #   Silas.agent.start(input: "...")            # the root app/agent
    #   Silas.agent(:clerk).start(input: "...")    # a named staff member
    def agent(name = nil)
      return NamedAgent.new(named_agent_scope!(name)) if name

      current_scope&.agent || config.agent_override || (@agent ||= Agent.load)
    end

    # Named-agent roster: { "name" => AgentScope }.
    def named_agent_scopes = config.named_agent_scopes&.call || {}

    # Memory is on when configured AND the table exists (upgrade-safe: an app
    # that hasn't run the 0.1.7 migration simply doesn't advertise the tools).
    def memory_enabled?
      config.memory && Memory.table_exists?
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
      false
    end
    def named_agent?(name) = named_agent_scopes.key?(name.to_s)

    def named_agent_scope!(name)
      named_agent_scopes.fetch(name.to_s) do
        known = named_agent_scopes.keys
        raise Error, "unknown agent #{name.inspect}" \
                     "#{known.any? ? " (known: #{known.join(', ')})" : " — no app/agents/ directories found"}"
      end
    end

    # Subagent roster: [[name, description], ...] (model-visible, so it's in the
    # root digest via Delegate.description).
    def subagent_index = config.subagent_index&.call || []
    def subagent?(name) = subagent_index.any? { |n, _| n == name.to_s }
    def subagent_scope(name) = config.subagent_scopes&.call&.fetch(name.to_s)

    # The scope a session's turns must run under: nil for the root agent,
    # otherwise the named-agent or subagent scope matching session.agent_name.
    # Fails loud on an unknown name — a session pointing at a deleted agent
    # directory must never silently run with the root agent's tools.
    def scope_for_session(session)
      name = session.agent_name.to_s
      return nil if name.empty? || name == "agent"

      named_agent_scopes[name] || config.subagent_scopes&.call&.[](name) or
        raise Error, "session #{session.id} belongs to agent #{name.inspect}, " \
                     "but no app/agents/#{name} or app/agent/subagents/#{name} exists"
    end

    # ---- scope switching -----------------------------------------------------

    SCOPE_KEY = :silas_agent_scope

    def current_scope
      ActiveSupport::IsolatedExecutionState[SCOPE_KEY]
    end

    # Run a block under an AgentScope. Nestable (delegation inside a named
    # agent restores the outer scope on exit) and isolated per execution
    # context — no global config is mutated, so concurrent jobs are safe.
    def with_agent_scope(scope)
      previous = ActiveSupport::IsolatedExecutionState[SCOPE_KEY]
      ActiveSupport::IsolatedExecutionState[SCOPE_KEY] = scope
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[SCOPE_KEY] = previous
    end
  end
end

require "silas/engine" if defined?(::Rails::Engine)
