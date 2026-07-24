module Silas
  class Configuration
    # Inference engine seam: :ruby_llm, or any object responding to #execute_step.
    attr_accessor :engine
    # Default model when agent.yml doesn't specify one.
    attr_accessor :default_model
    # Active Job queue for agent turns.
    attr_accessor :queue_name
    # Optional hook wrapping every model call — e.g. ruby_llm-resilience:
    #   config.around_model_call = ->(ctx, &call) { RubyLLM::Resilience.chain(:anthropic) { call.() } }
    attr_accessor :around_model_call
    # How long a parked approval (or in-doubt invocation) waits before expiring.
    # eve parks forever; Silas expires (parked-forever ghosts are a bug, not a feature).
    attr_accessor :approval_ttl
    # Hard cap on model calls per turn (agent.yml can lower it per-agent).
    attr_accessor :max_steps
    # Continuation isolation for loop steps. true in production (persistence
    # per step — the durability contract); specs may disable for inline runs.
    attr_accessor :isolate_steps
    # Injectable seams until/beyond the Registry: name -> tool object, the tool
    # schema list for the model, and the definitions digest for the
    # nondeterminism guard. The Registry wires real defaults at boot.
    attr_accessor :tool_resolver, :tool_definitions, :definitions_digest, :skills, :schedules
    # Subagents: the roster (name+description) and per-name scope builders, plus
    # the active-agent overrides swapped in during a nested run.
    attr_accessor :subagent_index, :subagent_scopes, :agent_override, :instructions_dir

    # Named top-level agents (app/agents/<name>/): lambda -> { name => AgentScope }.
    attr_accessor :named_agent_scopes

    # Memory (silas_memories): memory=false disables entirely; memory_approval
    # :always parks every remember for a human (default), :never auto-approves.
    attr_accessor :memory, :memory_approval, :memory_injection_limit
    # Channels: name -> Channel subclass (wired by the Registry). Slack creds
    # default to credentials.dig(:silas, :slack, ...); nil disables Slack.
    attr_accessor :channel_resolver
    attr_writer :slack_signing_secret, :slack_bot_token
    # Bind host for the in-process MCP server (Mcp::Server — the "mount your
    # tools as MCP" seam).
    attr_accessor :mcp_server_host

    # Removed in 0.2 with the :agent_sdk engine. Accepted as warning no-ops for
    # one release so an existing initializer doesn't crash at boot; hard removal
    # in 0.3.
    REMOVED_AGENT_SDK_OPTIONS = %i[
      auth agent_sdk_claude_bin agent_sdk_model agent_sdk_mcp_host
      agent_sdk_mcp_timeout_ms agent_sdk_cli_version_range
    ].freeze

    REMOVED_AGENT_SDK_OPTIONS.each do |option|
      define_method("#{option}=") { |_value| warn_removed_agent_sdk_option(option) }
      define_method(option) do
        warn_removed_agent_sdk_option(option)
        nil
      end
    end

    def warn_removed_agent_sdk_option(option)
      message = "[Silas] config.#{option} was removed in 0.2 with the :agent_sdk engine and " \
                "is now a no-op — delete it from your initializer (hard removal in 0.3)."
      (defined?(::Rails) && ::Rails.logger ? ::Rails.logger.warn(message) : nil) || Kernel.warn(message)
    end
    # Inbox (mountable UI at /silas/inbox).
    #   inbox_auth        — deny-by-default lambda; the host renders/head-404s to
    #                       DENY and passes by NOT rendering (resilience pattern).
    #   inbox_public_read — reads render for anyone; approve/decline still gated.
    #   inbox_actor       — controller -> identity string (approved_by/decline by:).
    #   model_prices      — model id -> {in:, out:} cost-units per 1k tokens,
    #                       where 1_000_000 units = $1 (so a $3/M-token input rate
    #                       is 3000 units/1k). Cost.format divides by 1e6.
    attr_accessor :inbox_auth, :inbox_public_read, :inbox_actor, :model_prices
    # Force-disable live broadcasting even when turbo-rails is present (nil = auto).
    attr_accessor :inbox_streaming
    # Evals: where *_eval.rb scenarios live, and an optional custom LLM grader.
    attr_accessor :eval_dir, :eval_grader
    # Connections: a test seam for injecting a fake MCP client ->(connection){ client }.
    attr_accessor :mcp_client_factory
    # Sandbox: :none (default, code exec off) | :docker | any object responding
    # to #run. Docker knobs are inert unless :docker.
    attr_accessor :sandbox, :sandbox_image, :sandbox_network, :sandbox_memory,
                  :sandbox_cpus, :sandbox_pids, :sandbox_workdir, :sandbox_docker_bin, :sandbox_timeout

    def slack_signing_secret
      @slack_signing_secret || Rails.application.credentials.dig(:silas, :slack, :signing_secret)
    end

    def slack_bot_token
      @slack_bot_token || Rails.application.credentials.dig(:silas, :slack, :bot_token)
    end

    def initialize
      @engine = :ruby_llm
      # Must be resolvable by the installed ruby_llm's model registry — newer
      # Claude models may need `RubyLLM.models.refresh!` before they resolve.
      @default_model = "claude-opus-4-8"
      @queue_name = :default
      @around_model_call = nil
      @approval_ttl = 7.days
      @max_steps = 25
      @isolate_steps = true
      @tool_resolver = nil
      @tool_definitions = nil
      @definitions_digest = nil
      @skills = nil
      @schedules = nil
      @subagent_index = nil
      @subagent_scopes = nil
      @agent_override = nil
      @instructions_dir = nil
      @channel_resolver = nil
      @slack_signing_secret = nil
      @slack_bot_token = nil
      @mcp_server_host = "127.0.0.1"
      @eval_dir = "test/agent_evals"
      @eval_grader = nil
      @sandbox = :none
      @memory = true
      @memory_approval = :always
      @memory_injection_limit = 8
      @sandbox_image = nil
      @sandbox_network = "none"
      @sandbox_memory = "512m"
      @sandbox_cpus = "1"
      @sandbox_pids = 256
      @sandbox_workdir = "/workspace"
      @sandbox_docker_bin = "docker"
      @sandbox_timeout = 30
      @inbox_auth = ->(controller) { controller.head :not_found } # deny by default
      @inbox_public_read = false
      @inbox_actor = ->(controller) { controller.try(:current_user)&.try(:email) || "inbox" }
      # Current Claude rates as cost-units per 1k tokens (1e6 units = $1):
      # Opus 4.8 $5/$25, Sonnet $3/$15, Haiku $1/$5 per million tokens.
      @model_prices = {
        "claude-opus-4-8" => { in: 5000, out: 25_000 },
        "claude-sonnet-5" => { in: 3000, out: 15_000 },
        "claude-sonnet-4-6" => { in: 3000, out: 15_000 },
        "claude-haiku-4-5" => { in: 1000, out: 5000 },
        "claude-haiku-4-5-20251001" => { in: 1000, out: 5000 }
      }
    end

    def validate!
      boot_guard!
      self
    end

    # Fail-loud misconfiguration checks, run from Silas.configure and at boot.
    def boot_guard!
      if engine == :agent_sdk
        raise BootGuardError,
              "the :agent_sdk engine was removed in Silas 0.2 — the claude -p subprocess " \
              "integration is gone (its subscription-auth rationale was unreachable). " \
              "Use engine :ruby_llm, the production path."
      end

      check_provider_credentials!
      warn_unsafe_queue_adapter!
    end

    # The most common first-run failure: no provider key configured, so the
    # first turn dies deep inside RubyLLM with a third-party error. Surface it
    # at boot with the fix. Raises in production (a keyless prod deploy is
    # always a misconfiguration); warns in development so a fresh app can
    # still boot and browse the inbox before a key exists.
    def check_provider_credentials!
      return unless engine == :ruby_llm && defined?(::RubyLLM)

      providers = ::RubyLLM::Provider.providers.values
      configured = providers.any? do |provider|
        requirements = provider.configuration_requirements
        requirements.any? && requirements.all? { |key| ::RubyLLM.config.public_send(key).present? }
      end
      return if configured

      message = "[Silas] engine :ruby_llm has no configured provider — no API key is set on " \
                "RubyLLM.config. Set one in config/initializers/ruby_llm.rb, e.g. " \
                "RubyLLM.configure { |c| c.anthropic_api_key = ENV[\"ANTHROPIC_API_KEY\"] } " \
                "— the first agent turn will fail without it."
      raise BootGuardError, message if defined?(::Rails) && ::Rails.env.production?

      (defined?(::Rails) && ::Rails.logger ? ::Rails.logger.warn(message) : nil) || Kernel.warn(message)
    rescue BootGuardError
      raise
    rescue StandardError
      nil # a diagnostic must never break boot
    end

    # Silas's durability and exactly-once guarantees rest on the queue adapter:
    # a turn's jobs must run one-at-a-time and continuation retries must run in a
    # FRESH execution after the prior one committed. The in-process Async adapter
    # (ActiveJob's dev default) breaks both — it runs a re-enqueued continuation
    # on a thread pool concurrently with the original, which double-executes
    # steps and violates the single-active-turn invariant (a re-run model call
    # mints new tool_call ids the ledger cannot dedup). Solid Queue — or any
    # durable, serializing, DB-backed adapter — is required to run agents; the
    # synchronous :inline adapter is safe for scripts and demos (no durability).
    #
    # RAISES in production — running agents on the Async adapter there silently
    # voids the durability contract. Warns in development (Rails' dev default
    # is :async and a fresh app must still boot).
    def warn_unsafe_queue_adapter!
      return unless defined?(::ActiveJob::Base)

      name = ::ActiveJob::Base.queue_adapter.class.name.to_s
      return unless name.include?("AsyncAdapter")

      message = "[Silas] ActiveJob is using the in-process Async queue adapter. " \
                "This runs continuation retries on a thread pool concurrently with " \
                "the original job, which double-executes agent steps and breaks " \
                "exactly-once tool effects. Use :solid_queue (production) or " \
                ":inline (scripts/demos). See Silas DEPLOY.md."
      raise BootGuardError, message if defined?(::Rails) && ::Rails.env.production?

      (defined?(::Rails) && ::Rails.logger ? ::Rails.logger.warn(message) : nil) || Kernel.warn(message)
    rescue BootGuardError
      raise
    rescue StandardError
      # A diagnostic must never break boot.
      nil
    end
  end
end
