Silas.configure do |config|
  # Inference engine: :ruby_llm (API key, any provider RubyLLM supports), or
  # any object responding to #execute_step. See silas/README.
  config.engine = :ruby_llm

  # Any model your installed ruby_llm's registry resolves (newer models may
  # need `RubyLLM.models.refresh!` first). "claude-sonnet-5" is the balanced
  # default; "claude-haiku-4-5" is fastest/cheapest; Opus models are the most
  # capable and the most expensive — set per-turn budgets in agent.yml before
  # reaching for one.
  config.default_model = "claude-sonnet-5"

  # The operator inbox (mounted at /silas/inbox) is DENY-BY-DEFAULT — invisible
  # until you wire auth. The lambda DENIES by rendering (or head-ing) and
  # PASSES by not rendering. Devise-style example:
  # config.inbox_auth = ->(controller) { controller.head :not_found unless controller.current_user&.admin? }
  # config.inbox_public_read = true   # read-only demo mode; writes stay gated

  # Parked approvals expire after this long (the turn fails as approval_expired).
  # config.approval_ttl = 7.days

  # Hard cap on model calls per turn (agent.yml limits.max_steps overrides).
  # config.max_steps = 25

  # Wrap every model call — e.g. ruby_llm-resilience:
  # config.around_model_call = ->(ctx, &call) { RubyLLM::Resilience.chain(:anthropic) { call.() } }

  # Sandbox for the run_code tool: :none (default, code exec off), :docker, or
  # a hermetic backend (gem "hermetic"), e.g. Hermetic.gvisor(image: "python:3.12-slim").
  # config.sandbox = :none

  # Memory (the remember/recall tools): on by default, and every remember
  # PARKS for human approval. :never auto-approves; config.memory = false
  # disables memory entirely.
  # config.memory_approval = :always

  # Cost accounting price overrides: cost-units per 1k tokens, where
  # 1_000_000 units = $1 (so a $3/M-token rate is 3000).
  # config.model_prices["your-fine-tune"] = { in: 3000, out: 15_000 }

  # Where eval scenarios live (bin/rails silas:eval).
  # config.eval_dir = "test/agent_evals"
end
