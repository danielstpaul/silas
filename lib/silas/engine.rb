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
      next unless agent_dir.exist?

      unless defined?(::Agent)
        Object.const_set(:Agent, Module.new)
      end
      app.autoloaders.main.push_dir(agent_dir, namespace: ::Agent)

      # Markdown/YAML (instructions.md, agent.yml, skills/*.md) are not Ruby;
      # keep Zeitwerk away from them. tools/, schedules/ (.rb handlers), and
      # channels/ all autoload under the Agent namespace via push_dir above.
      app.autoloaders.main.ignore(agent_dir.join("skills"))
    end

    initializer "silas.boot_guard", after: :load_config_initializers do
      Silas.config.boot_guard!
    end

    # Registry rebuilds on every code reload in development, once in production.
    initializer "silas.registry" do |app|
      next unless app.root.join("app/agent").exist?

      app.config.to_prepare { Silas::Registry.install!(root: Rails.root) }
    end
  end
end
