require "rails/generators"

module Silas
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_initializer
        template "initializer.rb", "config/initializers/silas.rb"
        # ruby_llm reads no provider keys from ENV on its own; without this the
        # first model call raises ConfigurationError. Brownfield apps often
        # already configure ruby_llm themselves — never touch an existing one
        # (not even a conflict prompt: an accidental Y clobbers production
        # provider config).
        if File.exist?(File.join(destination_root, "config/initializers/ruby_llm.rb"))
          say_status :skip, "config/initializers/ruby_llm.rb exists — left untouched", :yellow
        else
          template "ruby_llm.rb", "config/initializers/ruby_llm.rb"
        end
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

      # Evals as a deploy gate: an example scenario + a bin/ci wrapper. Rails
      # 8.1 apps ship their own bin/ci (rubocop, brakeman, tests) — never
      # clobber it; tell the user to add the eval gate to theirs instead.
      def create_eval_gate
        template "example_eval.rb", "test/agent_evals/example_eval.rb"

        if File.exist?(File.expand_path("bin/ci", destination_root))
          say "bin/ci already exists — left untouched. Add `bin/rails silas:eval` " \
              "to it to gate deploys on agent evals.", :yellow
        else
          copy_file "bin_ci", "bin/ci"
          chmod "bin/ci", 0o755
        end
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
            2. export ANTHROPIC_API_KEY=sk-ant-...  (config/initializers/ruby_llm.rb reads it)
            3. Edit app/agent/instructions.md (your agent's persona)
            4. Write tools in app/agent/tools/ (keyword signature = schema)
            5. Talk to it: bin/rails silas:chat  (or Silas.agent.start(input: "hello"))
            6. Schedules: edit app/agent/schedules/*, then `bin/rails silas:schedules`
            7. Channels (optional): set credentials.silas.slack.{signing_secret,bot_token}
               for Slack; route inbound mail to Silas::AgentMailbox for email.
               Delete app/agent/channels/{slack,email}.rb to disable.
            8. Inbox: live at /silas/inbox once you set config.inbox_auth
               (deny-by-default until you do).
        MSG
      end
    end
  end
end
