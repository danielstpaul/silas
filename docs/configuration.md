# Configuration reference

Everything lives in one block, usually in `config/initializers/silas.rb` (the
installer generates a commented starter):

```ruby
Silas.configure do |c|
  # ...
end
```

## Inference

| Option | Default | Meaning |
|---|---|---|
| `adapter` | `:ruby_llm` | The inference seam. `:ruby_llm` (any provider RubyLLM supports), or any object responding to `#execute_step` — the eval harness, the chaos suite, and the template's keyless demo all inject one. |
| `default_model` | `"claude-sonnet-4-5"` | Used when `agent.yml` doesn't set `model:`. Must resolve in your installed RubyLLM registry. |
| `around_model_call` | `nil` | Wrap every model call — e.g. `->(ctx, &call) { RubyLLM::Resilience.chain(:anthropic) { call.() } }`. |
| `queue_name` | `:default` | Active Job queue for agent turns. |

Which provider serves a turn is decided by the model id — OpenRouter,
OpenAI-compatible gateways, Bedrock/Vertex/Azure, and local runtimes are all
recipes in [providers](providers.md).

## The loop

| Option | Default | Meaning |
|---|---|---|
| `max_steps` | `25` | Hard cap on model calls per turn; `agent.yml` `limits.max_steps` overrides per agent. Hitting it fails the turn (`max_steps`). |
| `compact_at` | `0.9` | Context compaction trigger. A Float in (0, 1] = fraction of the model's registry context window; an Integer = absolute token threshold (the form custom adapters need); `nil`/`false` disables. Compaction summarises **prior turns** into a persisted, exactly-once row — the current turn is never compacted, and replays stay byte-identical. |
| `isolate_steps` | `true` | Continuation isolation per step — the durability contract. Leave on; specs may disable for inline runs. |

## Approvals & questions

| Option | Default | Meaning |
|---|---|---|
| `approval_ttl` | `7.days` | How long a parked approval (or in-doubt invocation) waits before expiring. Parked-forever ghosts are a bug, not a feature. |
| `ask_question` | `true` | The built-in tool that parks the turn to ask the operator something. **Toggling it changes the definitions digest** — settle parked turns before flipping, or they fail loudly on resume (the nondeterminism guard working as designed). |

## Memory

| Option | Default | Meaning |
|---|---|---|
| `memory` | `true` | `false` removes the memory tools entirely (digest note above applies). |
| `memory_approval` | `:always` | Every `remember` parks a card for a human; `:never` auto-approves. |
| `memory_injection_limit` | `8` | How many recent memories are injected into each turn; `recall` digs deeper on demand. |

## Inbox (`/silas/inbox`)

| Option | Default | Meaning |
|---|---|---|
| `inbox_auth` | deny (404) | The lambda DENIES by rendering (or `head`-ing) and PASSES by not rendering — Devise-compatible: `->(controller) { controller.head :not_found unless controller.current_user&.admin? }`. |
| `inbox_public_read` | `false` | Read-only for anyone; approve/decline/answer stay gated. |
| `inbox_actor` | `current_user&.email \|\| "inbox"` | Identity recorded on approvals/declines/answers made in the inbox. |
| `inbox_streaming` | `nil` (auto) | Live Turbo updates when the host has `turbo-rails`; `false` forces the polling fallback. |
| `model_prices` | `{}` | **Override** map for cost accounting: `{"model-id" => { in:, out: }}` in units per 1k tokens, 1e6 units = $1 (a $3/MTok rate is `3000`). Everything else prices from RubyLLM's registry. |

## JSON API (`/silas/api/v1`)

| Option | Default | Meaning |
|---|---|---|
| `api_auth` | deny (404) | Same contract as `inbox_auth`. |
| `api_actor` | `"api"` | Identity recorded on approvals made through the API. |
| `api_stream_poll_interval` | `0.5` | Seconds between SSE row polls. |
| `api_stream_max_duration` | `300` | Seconds before an SSE stream closes itself (clients reconnect with `Last-Event-ID`); bounds thread hold. |

## Channels

| Option | Default | Meaning |
|---|---|---|
| `slack_signing_secret` / `slack_bot_token` | `credentials.silas.slack.*` | Explicit setters override the credentials path; `nil` disables Slack. |
| `channel_routes` | `{}` | Which agent an inbound thread wakes: `{ "slack" => { "C0BILLING" => "bookkeeper" }, "email" => { "billing@shop.test" => "bookkeeper" } }`. Unmatched threads wake the root agent. Names are checked at boot against `app/agents/` — a typo fails the deploy, never a webhook. See [channels](channels.md#routing-which-agent-wakes). |

## Evals

| Option | Default | Meaning |
|---|---|---|
| `eval_dir` | `"test/agent_evals"` | Where `*_eval.rb` scenarios live (`bin/rails silas:eval`). |
| `eval_grader` | `nil` | Custom LLM grader for `assert_rubric`; offline, rubric asserts skip rather than fail. |

## Sandbox

| Option | Default | Meaning |
|---|---|---|
| `sandbox` | `:none` | Code execution off. `:docker` (interim), or any object responding to `#run` — e.g. `Hermetic.gvisor(image: "python:3.12-slim")`. Configuring one advertises the `run_code` tool automatically. |
| `sandbox_image` / `sandbox_network` / `sandbox_memory` / `sandbox_cpus` / `sandbox_pids` / `sandbox_workdir` / `sandbox_docker_bin` / `sandbox_timeout` | `nil` / `"none"` / `"512m"` / `"1"` / `256` / `"/workspace"` / `"docker"` / `30` | Docker knobs; inert unless `sandbox = :docker`. |

## MCP & testing seams

| Option | Default | Meaning |
|---|---|---|
| `mcp_server_host` | `"127.0.0.1"` | Bind host for the in-process MCP server (`Silas::Mcp::Server`, serving *your* tools to MCP clients). Inert — nothing starts that server yet; see [connections](connections.md). |
| `mcp_client_factory` | `nil` | `->(connection) { client }` — inject a fake MCP client per connection in tests. |

The remaining accessors (`tool_resolver`, `tool_definitions`,
`definitions_digest`, `skills`, `schedules`, `subagent_*`,
`named_agent_scopes`, `channel_resolver`, `instructions_dir`,
`agent_override`) are internal wiring seams the Registry fills at boot — test
hooks, not app configuration.

## Boot guards (fail-loud misconfiguration)

Two checks run at boot and **raise in production**, warn in development:

- **No provider key configured** while `adapter = :ruby_llm` — the most common
  first-run failure, surfaced at boot with the fix instead of dying inside the
  first turn.
- **ActiveJob on the in-process `:async` adapter** — it runs a re-enqueued
  continuation concurrently with the original, double-executing steps and
  voiding exactly-once. Use Solid Queue (production) or `:inline`
  (scripts/demos). `bin/rails silas:doctor` checks both, everywhere.
