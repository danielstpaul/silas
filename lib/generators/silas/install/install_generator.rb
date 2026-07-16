require "rails/generators"

module Silas
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_initializer
        template "initializer.rb", "config/initializers/silas.rb"
      end

      def create_agent_directory
        template "instructions.md", "app/agent/instructions.md"
        template "agent.yml", "app/agent/agent.yml"
        template "example_tool.rb", "app/agent/tools/example_tool.rb"
        template "example_skill.md", "app/agent/skills/example.md"
        template "example_schedule.md", "app/agent/schedules/example.md"
      end

      # Channels are opt-in: scaffold the two reference bindings + mount the
      # engine that serves their webhooks. Delete a channel file to disable it.
      def create_channels
        template "channel_slack.rb", "app/agent/channels/slack.rb"
        template "channel_email.rb", "app/agent/channels/email.rb"
      end

      def mount_engine
        route 'mount Silas::Engine => "/silas"'
      end

      # Evals as a deploy gate: an example scenario + a bin/ci wrapper.
      def create_eval_gate
        template "example_eval.rb", "test/agent_evals/example_eval.rb"
        copy_file "bin_ci", "bin/ci"
        chmod "bin/ci", 0o755
      end

      def add_rescuer_recurring_task
        recurring = "config/recurring.yml"
        entry = <<~YAML

          # Silas: retries jobs failed by dead-worker reaping/pruning and sweeps
          # expired approvals. Part of the durability contract — do not remove.
          silas_dead_job_rescuer:
            class: Silas::DeadJobRescuerJob
            queue: default
            schedule: every 30 seconds
        YAML

        if File.exist?(File.expand_path(recurring, destination_root))
          append_to_file recurring, entry.indent(2)
        else
          create_file recurring, "production:#{entry.indent(2)}"
        end
      end

      def install_migrations
        rake "silas:install:migrations"
      rescue StandardError
        say "Run `bin/rails silas:install:migrations db:migrate` to install Silas's tables.", :yellow
      end

      def show_next_steps
        say <<~MSG, :green

          Silas installed. Next:
            1. bin/rails db:migrate
            2. Edit app/agent/instructions.md (your agent's persona)
            3. Write tools in app/agent/tools/ (keyword signature = schema)
            4. Silas.agent.start(input: "hello")
            5. Schedules: edit app/agent/schedules/*, then `bin/rails silas:schedules`
            6. Channels (optional): set credentials.silas.slack.{signing_secret,bot_token}
               for Slack; route inbound mail to Silas::AgentMailbox for email.
               Delete app/agent/channels/{slack,email}.rb to disable.
            7. Inbox: live at /silas/inbox once you set config.inbox_auth
               (deny-by-default until you do).
        MSG
      end
    end
  end
end
