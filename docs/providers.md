# Providers & gateways

Silas has exactly one inference seam: the `:ruby_llm` adapter. Every model
call goes through [RubyLLM](https://rubyllm.com), so every provider RubyLLM
speaks — Anthropic, OpenAI, Gemini, Bedrock, Vertex AI, Azure, Mistral,
DeepSeek, Perplexity, xAI, OpenRouter, local runtimes — is available to your
agents with zero Silas-specific glue. Keys live in
`config/initializers/ruby_llm.rb`; **which provider serves a turn is decided
by the model id**. Nothing in `app/agent/` changes when the provider does.

## How a model id picks a provider

RubyLLM ships a model registry (1,100+ entries, refreshed upstream from
[models.dev](https://models.dev)). Silas resolves the agent's `model:` — from
`agent.yml`, falling back to `config.default_model` — against that registry;
the matching entry names the provider, and the adapter builds that provider's
client. The same entry supplies the numbers Silas runs on, per
(model, provider):

- **pricing** — the cost lines in the inbox and the `max_cost` budget;
- **context window** — the `compact_at` compaction threshold.

So switching provider is switching model id. A model the registry doesn't
know fails fast at the first step with the fix in the error
(`RubyLLM.models.refresh!`, or pick a registry model). And because a
registry's tie-breaks can change across upgrades, Silas stamps the resolved
provider on every step row — historical cost lines price against the
(model, provider) that actually served them, forever.

## Direct providers

The installer's `config/initializers/ruby_llm.rb` maps environment keys in —
RubyLLM never reads provider keys from the environment by itself:

```ruby
RubyLLM.configure do |c|
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
end
```

Every provider follows the same pattern (`openai_api_key`,
`gemini_api_key`, …— the full list is in
[RubyLLM's configuration docs](https://rubyllm.com/configuration/)). For
cloud-platform shops the "enterprise gateway" is usually just the native
provider:

| Platform | Keys |
|---|---|
| AWS Bedrock | `bedrock_api_key`, `bedrock_secret_key`, `bedrock_region` (+ optional `bedrock_session_token`) |
| GCP Vertex AI | `vertexai_project_id`, `vertexai_location` (+ optional `vertexai_service_account_key`) |
| Azure OpenAI | `azure_api_base`, `azure_api_key` (or `azure_ai_auth_token`) |

Verify any of this with `bin/rails silas:doctor` — it reports which providers
have credentials configured and resolves your default model with its price:

```
 ✓ provider credentials — anthropic
 ✓ model claude-sonnet-4-5 — anthropic · $3/$15 per MTok
```

## OpenRouter: one key, 300+ models

[OpenRouter](https://openrouter.ai) is a first-class RubyLLM provider, and
the registry ships its catalog (341 models as of ruby_llm 1.16) — one key
buys your agents Claude, GPT, Gemini, Llama, DeepSeek and the rest, billed
in one place.

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |c|
  c.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
end
```

Routed models use slash-form ids — `creator/model`, exactly as OpenRouter
lists them:

```yaml
# app/agent/agent.yml
model: anthropic/claude-sonnet-4.5   # via OpenRouter
```

or globally:

```ruby
Silas.configure do |c|
  c.default_model = "anthropic/claude-sonnet-4.5"
end
```

The two id families never collide: `claude-sonnet-4-5` is Anthropic direct,
`anthropic/claude-sonnet-4.5` is the same model via OpenRouter, and each
resolves to its own registry entry. That per-route entry is the one your
cost lines and compaction thresholds follow — the route you run, not the
origin provider. Concretely, in the shipped registry the direct entry lists
a 200K context window while OpenRouter's route lists 1M, so `compact_at`
triggers where the route actually overflows.

`silas:doctor` confirms the whole chain:

```
 ✓ provider credentials — openrouter
 ✓ model anthropic/claude-sonnet-4.5 — openrouter · $3/$15 per MTok
```

## OpenAI-compatible gateways

Self-hosted and enterprise gateways (LiteLLM, Vercel AI Gateway, an internal
proxy) mostly speak the OpenAI chat-completions dialect. Two shapes:

**The gateway serves OpenAI model ids** (`gpt-5.2`, …) — point the OpenAI
provider at it:

```ruby
RubyLLM.configure do |c|
  c.openai_api_key  = ENV["GATEWAY_API_KEY"]
  c.openai_api_base = "https://gateway.internal/v1"
end
```

**The gateway serves models.dev slash ids** (`anthropic/claude-sonnet-4.5`,
…, as Vercel's AI Gateway does) — repoint the OpenRouter provider, which
already speaks plain chat-completions against exactly those ids:

```ruby
RubyLLM.configure do |c|
  c.openrouter_api_key  = ENV["AI_GATEWAY_API_KEY"]
  c.openrouter_api_base = "https://ai-gateway.vercel.sh/v1"
end
```

Either way the model id must still resolve in the registry — the registry
entry is where Silas gets pricing and the context window, and a gateway
that bills differently can be corrected per model with the
`config.model_prices` override ([configuration](configuration.md)).

Two gateway footnotes, both cheap to check with one real turn:

- RubyLLM renders system messages as role `developer` (OpenAI's current
  dialect) through these providers. OpenRouter normalises it; if your
  gateway insists on `system`, set `c.openai_use_system_role = true`.
- Streaming must pass through as SSE. If the operator inbox shows a turn
  completing without live text, the gateway buffered the stream.

## Local runtimes

Ollama and GPUStack are RubyLLM providers too (`ollama_api_base`,
`gpustack_api_base`/`gpustack_api_key`). Local models aren't in the shipped
registry, so refresh it after configuring — `RubyLLM.models.refresh!` asks
every configured provider for its live model list and merges the results —
then use the id it lists. Local models carry no registry pricing: the inbox
shows their token counts with "cost unavailable", and a `max_cost` budget
can't bind (only priced tokens count toward it) — list the model in
`config.model_prices` to restore both.

## Failover and wrapping

Provider outages, rate-limit retries and model failover belong at the
inference seam, not in your tools. `config.around_model_call` wraps every
model call the loop makes:

```ruby
Silas.configure do |c|
  c.around_model_call = ->(ctx, &call) do
    RubyLLM::Resilience.chain(:anthropic) { call.() }
  end
end
```

Whatever runs inside still lands in the same durable step — a failover
retry that succeeds is recorded exactly like a first-try success.
