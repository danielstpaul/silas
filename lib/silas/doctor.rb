require "erb"
require "yaml"

module Silas
  # One command for every known first-run failure mode: provider key, queue
  # adapter, model resolution, migrations, tool validation, the rescuer
  # entry, cable adapter for live streaming, and auth wiring. Each check was
  # already written somewhere in the codebase — this makes them reachable as
  # `bin/rails silas:doctor`.
  class Doctor
    Check = Struct.new(:status, :label, :detail) # status: :pass | :warn | :fail

    # Rails defaults development to :async, which the queue_adapter check below
    # FAILS — so a stock app fails the doctor the installer told it to run. The
    # remedy travels with the failure, and the install generator prints this
    # same constant when it detects :async, so the two surfaces can't drift.
    # Printed, never written: database.yml and cable.yml belong to the host app.
    ASYNC_QUEUE_REMEDY = <<~MSG.freeze
      Add to config/environments/development.rb:

          config.active_job.queue_adapter = :solid_queue
          config.solid_queue.connects_to = { database: { writing: :queue } }

      and a queue database to config/database.yml (SQLite shown — drop the
      connects_to line above if Solid Queue shares your primary database):

          development:
            primary:
              <<: *default
              database: storage/development.sqlite3
            queue:
              <<: *default
              database: storage/development_queue.sqlite3
              migrations_paths: db/queue_migrate

      Then `bin/rails db:prepare`, and run the worker next to the server:
      `bin/jobs`. On an app that predates Rails 8, `bundle add solid_queue &&
      bin/rails solid_queue:install` first. For scripts and demos `:inline` is
      also safe — synchronous, no durability.
    MSG

    def self.run(root: Rails.root) = new(root: root).run

    def initialize(root:)
      @root = Pathname(root)
    end

    def run
      [
        provider_credentials, queue_adapter, model_resolution, migrations,
        agent_directory, rescuer_entry, streaming_cable, auth_wiring
      ].flatten.compact
    end

    private

    def provider_credentials
      configured = ::RubyLLM::Provider.providers.select do |_slug, provider|
        requirements = provider.configuration_requirements
        requirements.any? && requirements.all? { |key| ::RubyLLM.config.public_send(key).present? }
      end.keys
      if configured.any?
        Check.new(:pass, "provider credentials", configured.join(", "))
      else
        Check.new(:fail, "provider credentials",
                  "no API key on RubyLLM.config — set one in config/initializers/ruby_llm.rb; " \
                  "the first turn will fail without it")
      end
    rescue StandardError => e
      Check.new(:warn, "provider credentials", "could not inspect RubyLLM config (#{e.class})")
    end

    def queue_adapter
      name = ActiveJob::Base.queue_adapter.class.name.to_s
      case name
      when /SolidQueue/
        Check.new(:pass, "queue adapter", "solid_queue (durable)")
      when /AsyncAdapter/
        Check.new(:fail, "queue adapter",
                  "in-process :async double-executes continuation steps and voids the durability " \
                  "contract — use :solid_queue (see DEPLOY.md)\n\n#{ASYNC_QUEUE_REMEDY.indent(3).chomp}")
      when /InlineAdapter/
        Check.new(:warn, "queue adapter", "inline — fine for scripts and demos, no durability")
      else
        Check.new(:warn, "queue adapter",
                  "#{name.demodulize} — no dead-job rescue path: DeadJobRescuerJob sweeps expired approvals " \
                  "but returns early unless SolidQueue is defined, so a job killed with its worker is never " \
                  "retried and a turn stranded mid-tool stays running with its in-doubt invocation unswept. " \
                  "Durability requires a serializing, DB-backed adapter.")
      end
    end

    def model_resolution
      model = Silas.agent.model
      info = ::RubyLLM.models.find(model)
      Check.new(:pass, "model #{model}",
                "#{info.provider} · $#{info.input_price_per_million}/$#{info.output_price_per_million} per MTok")
    rescue StandardError
      Check.new(:fail, "model #{model || '?'}",
                "not in ruby_llm's registry — `RubyLLM.models.refresh!` or pick a registry model")
    end

    def migrations
      missing = %w[silas_sessions silas_turns silas_steps silas_tool_invocations]
                .reject { |t| ActiveRecord::Base.connection.table_exists?(t) }
      if missing.any?
        return Check.new(:fail, "migrations",
                         "missing #{missing.join(', ')} — bin/rails silas:install:migrations db:migrate")
      end
      unless ActiveRecord::Base.connection.column_exists?(:silas_steps, :provider)
        return Check.new(:warn, "migrations", "0.3 migration pending — bin/rails silas:install:migrations db:migrate")
      end

      Check.new(:pass, "migrations", "all silas tables present")
    rescue StandardError => e
      Check.new(:fail, "database", "#{e.class}: #{e.message.lines.first&.strip}")
    end

    def agent_directory
      dir = @root.join("app/agent")
      return Check.new(:fail, "app/agent", "missing — bin/rails generate silas:install") unless dir.exist?

      checks = []
      checks << Check.new(:warn, "instructions", "app/agent/instructions.md missing") unless dir.join("instructions.md").exist?
      begin
        registry = Silas::Registry.new(root: @root)
        checks << Check.new(:pass, "tools", "#{registry.tools.size} tool(s) validate")
      rescue StandardError => e
        checks << Check.new(:fail, "tools", e.message)
      end
      checks
    end

    def rescuer_entry
      path = @root.join("config/recurring.yml")
      unless path.exist?
        return Check.new(:warn, "rescuer",
                         "config/recurring.yml missing — the dead-job rescuer is part of the durability contract")
      end
      if path.read.include?("silas_dead_job_rescuer")
        Check.new(:pass, "rescuer", "recurring entry present")
      else
        Check.new(:warn, "rescuer", "no silas_dead_job_rescuer entry — SIGKILL recovery won't run")
      end
    end

    def streaming_cable
      unless Silas::Inbox.streaming_available?
        return Check.new(:warn, "live streaming", "turbo-rails not bundled — the inbox falls back to a polling refresh")
      end

      cable = @root.join("config/cable.yml")
      adapter = begin
        cable.exist? ? YAML.safe_load(ERB.new(cable.read).result, aliases: true)&.dig(Rails.env.to_s, "adapter") : nil
      rescue StandardError
        nil
      end
      case adapter
      when "async"
        Check.new(:warn, "live streaming",
                  "cable adapter :async is single-process — token deltas emitted in the worker never " \
                  "reach the browser; use solid_cable or redis")
      when nil
        Check.new(:warn, "live streaming", "could not read a cable adapter from config/cable.yml")
      else
        Check.new(:pass, "live streaming", "cable adapter #{adapter}")
      end
    end

    def auth_wiring
      [
        auth_check("inbox auth", Silas.config.inbox_auth, "/silas/inbox", "config.inbox_auth"),
        auth_check("api auth", Silas.config.api_auth, "/silas/api/v1", "config.api_auth")
      ]
    end

    # The deny-by-default lambdas are defined inside silas/configuration.rb;
    # anything the host wired has a different source_location.
    def auth_check(label, auth_lambda, surface, option)
      if auth_lambda.respond_to?(:source_location) &&
         auth_lambda.source_location&.first.to_s.include?("silas/configuration")
        Check.new(:warn, label, "deny-by-default — #{surface} is invisible until you set #{option}")
      else
        Check.new(:pass, label, "configured")
      end
    end
  end
end
