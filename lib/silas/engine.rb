module Silas
  # The Rails engine (not to be confused with inference adapters under
  # Silas::Engines::*). Full engine: Silas is Rails-native by thesis.
  class Engine < ::Rails::Engine
    isolate_namespace Silas

    # Make app/agent/ a first-class app directory: files there autoload under
    # the bare Agent namespace, so app/agent/tools/issue_refund.rb defines
    # Agent::Tools::IssueRefund. Tool identity remains the filename.
    initializer "silas.agent_directory" do |app|
      agent_dir = app.root.join("app/agent")
      if agent_dir.exist?
        unless defined?(::Agent)
          Object.const_set(:Agent, Module.new)
        end
        app.autoloaders.main.push_dir(agent_dir, namespace: ::Agent)

        # Markdown/YAML (instructions.md, agent.yml, skills/*.md) are not Ruby;
        # keep Zeitwerk away from them. tools/, schedules/ (.rb handlers), and
        # channels/ all autoload under the Agent namespace via push_dir above.
        app.autoloaders.main.ignore(agent_dir.join("skills"))
      end

      # Named agents: app/agents/<name>/tools/x.rb autoloads as
      # Agents::<Name>::Tools::X — the staff pattern.
      agents_dir = app.root.join("app/agents")
      if agents_dir.exist?
        unless defined?(::Agents)
          Object.const_set(:Agents, Module.new)
        end
        app.autoloaders.main.push_dir(agents_dir, namespace: ::Agents)
        Dir[agents_dir.join("*/skills")].each { |d| app.autoloaders.main.ignore(d) }
      end
    end

    initializer "silas.boot_guard", after: :load_config_initializers do
      Silas.config.boot_guard!
    end

    # Live token streaming into the inbox trace: one process-wide subscriber on
    # "silas.delta"; a no-op unless turbo-rails is present and streaming is on.
    initializer "silas.delta_broadcaster" do
      Silas::Inbox::DeltaBroadcaster.subscribe!
    end

    # The trace partials render in TWO contexts: the inbox controllers (which
    # declare this helper) and Turbo's broadcast jobs, which render through the
    # HOST's default renderer — where an engine-scoped helper doesn't exist and
    # every broadcast died silently inside Turbo's job. Register it host-wide
    # so broadcast renders — and host apps embedding the trace partials in
    # their own pages — resolve it. (Routes inside those partials go through
    # TraceHelper#silas_engine_path, which needs no routing scope at all.)
    initializer "silas.trace_helper" do
      ActiveSupport.on_load(:action_controller_base) { helper Silas::Inbox::TraceHelper }
    end

    # Registry rebuilds on every code reload in development, once in production.
    initializer "silas.registry" do |app|
      next unless app.root.join("app/agent").exist? || app.root.join("app/agents").exist?

      app.config.to_prepare { Silas::Registry.install!(root: Rails.root) }
    end
  end
end
