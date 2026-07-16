Silas.configure do |config|
  # Inference engine: :ruby_llm (API key, any provider RubyLLM supports), or
  # :agent_sdk (a `claude -p` subprocess; API-key auth only). See silas/README.
  config.engine = :ruby_llm

  config.default_model = "claude-sonnet-5"

  # Parked approvals expire after this long (the turn fails as approval_expired).
  # config.approval_ttl = 7.days

  # Hard cap on model calls per turn (agent.yml limits.max_steps overrides).
  # config.max_steps = 25

  # Wrap every model call — e.g. ruby_llm-resilience:
  # config.around_model_call = ->(ctx, &call) { RubyLLM::Resilience.chain(:anthropic) { call.() } }
end
