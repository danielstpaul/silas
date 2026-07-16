# Active Job (Continuations) and Active Record are the chassis — load them
# even in --minimal host apps that skipped the railties.
require "active_job/railtie" if defined?(::Rails::Railtie)
require "active_record/railtie" if defined?(::Rails::Railtie)

require "silas/version"
require "silas/errors"
require "silas/configuration"
require "silas/ledger"
require "silas/tool"
require "silas/skill"
require "silas/schedule"
require "silas/schedule/compiler"
require "silas/agent_scope"
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
require "silas/budget"
require "silas/registry"
require "silas/agent"
require "silas/tools/load_skill"
require "silas/engines/base"
require "silas/agent_sdk/version_guard"
require "silas/agent_sdk/stream_parser"
require "silas/agent_sdk/cli"
require "silas/mcp/handler"
require "silas/mcp/server"
require "silas/engines/agent_sdk"
require "ruby_llm"
require "silas/engines/ruby_llm"
require "silas/message_builder"
require "silas/instructions"
require "silas/step_runner"
require "silas/subprocess_runner"
require "silas/eval" # after engines (ScriptedEngine < Engines::Base)
require "silas/chat"

module Silas
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config.validate!
      config
    end

    def reset_configuration! # for specs
      @config = nil
      @resolved_engine = nil
      @resolved_sandbox = nil
      @agent = nil
    end

    def sandbox_enabled? = ![ :none, nil ].include?(config.sandbox)

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
        else config.sandbox
        end
    end

    def reset_agent_memo! = (@agent = nil) # after Registry.install! swaps dirs

    # The inference adapter instance. config.engine may be a symbol (:ruby_llm,
    # :agent_sdk) or any object responding to #execute_step (specs, custom).
    def resolved_engine
      @resolved_engine ||=
        case config.engine
        when :ruby_llm then Engines::RubyLLM.new
        when :agent_sdk then Engines::AgentSdk.new
        when Symbol then raise Error, "unknown engine #{config.engine.inspect}"
        else config.engine
        end
    end

    def tool_resolver
      config.tool_resolver or raise Error, "no tool resolver configured (Registry boots one; specs must inject)"
    end

    def tool_definitions
      config.tool_definitions&.call || []
    end

    def skills
      config.skills&.call || []
    end

    def schedules
      config.schedules&.call || []
    end

    # The active agent definition. config.agent_override is set during a nested
    # subagent run; otherwise it's the root app/agent.
    def agent
      config.agent_override || (@agent ||= Agent.load)
    end

    # Subagent roster: [[name, description], ...] (model-visible, so it's in the
    # root digest via Delegate.description).
    def subagent_index = config.subagent_index&.call || []
    def subagent?(name) = subagent_index.any? { |n, _| n == name.to_s }
    def subagent_scope(name) = config.subagent_scopes&.call&.fetch(name.to_s)

    # Run a block with a subagent's scope swapped in as the active globals,
    # restoring afterward. Synchronous/depth-1 — safe because delegation runs
    # inline on one thread while the parent loop is paused in the delegate tool.
    def with_agent_scope(scope)
      saved = {
        tool_resolver: config.tool_resolver, tool_definitions: config.tool_definitions,
        definitions_digest: config.definitions_digest, skills: config.skills,
        agent_override: config.agent_override, instructions_dir: config.instructions_dir
      }
      config.tool_resolver = scope.resolver
      config.tool_definitions = -> { scope.definitions }
      config.definitions_digest = -> { scope.digest }
      config.skills = -> { scope.skills }
      config.agent_override = scope.agent
      config.instructions_dir = scope.dir
      yield
    ensure
      saved.each { |k, v| config.public_send("#{k}=", v) }
    end
  end
end

require "silas/engine" if defined?(::Rails::Engine)
