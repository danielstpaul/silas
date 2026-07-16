# Changelog

## 0.1.5

- **Turn cancellation.** `turn.cancel!` — a parked or queued turn settles to
  `canceled` immediately (pending approvals expire, so a late `approve!` can
  never zombie-resume it); a running turn is flagged and honored at the next
  step boundary, keeping the in-flight step's paid work. Engine-owned
  (`:agent_sdk`) turns cancel only before the subprocess starts (v1). New
  migration adds `silas_turns.cancel_requested_at`.
- **Resumable budget parks.** A turn that hits `max_cost` / `max_input_tokens` /
  `timeout` now PARKS at zero compute (state intact) instead of failing
  terminally. A human resumes it with `turn.raise_budget!(max_cost: 1.50)` —
  the top-up is recorded as a per-turn override and a fresh job replays
  completed steps from rows (no model re-calls, no re-effects), continuing
  where it left off. `bin/rails silas:chat` prompts for the top-up inline.
  New migration adds `silas_turns.budget_overrides` (run
  `bin/rails silas:install:migrations db:migrate` on upgrade). Notes: the
  timeout clock includes time spent parked — size a timeout top-up from
  elapsed wall-clock; budget parks have no TTL yet (visible in the inbox as
  waiting); an inbox top-up card is planned.

## 0.1.4

- **Fresh-app quickstart actually works.** A from-scratch install previously
  failed at its own post-install steps: the generated default model
  ("claude-sonnet-5") wasn't in ruby_llm 1.16's bundled registry, and no
  provider-key initializer was generated, so the first turn raised. The
  generator now emits `config/initializers/ruby_llm.rb` (maps
  `ANTHROPIC_API_KEY`), defaults to the registry-known `claude-opus-4-8`, and a
  missing model raises an actionable error suggesting
  `RubyLLM.models.refresh!`.
- **`silas:schedules` no longer crashes on the generator's own template.** The
  example schedule's ERB comment rendered a leading blank line the frontmatter
  parser rejected; template fixed and the parser now tolerates leading
  whitespace.
- **`bin/ci` is never clobbered.** Rails 8.1 ships a real bin/ci; the installer
  now leaves an existing one untouched and tells you to add
  `bin/rails silas:eval` to it.
- **Correct Opus 4.8 pricing.** Default `model_prices` had Opus 4.8 at $15/$75
  per MTok; it is $5/$25. Added Sonnet 4.6 and the `claude-haiku-4-5` alias.
- **ruby_llm dependency bounded `< 2`** (2.0 removes APIs the engine relies on).
- **`bin/rails silas:chat` — a terminal REPL for your agent.** The dev-loop a
  hosted platform gives you from its CLI, except there is no platform: it runs
  inside your app, tools hit your real dev database, and parked approvals prompt
  inline (`approve? [y]es / [d]ecline / [s]kip`) calling the same
  `approve!`/`decline!` as the inbox and Slack. `SESSION=id` resumes a session;
  a new message while a turn is parked steers you to the pending approvals. The
  task forces the synchronous `:inline` adapter for its own process (a REPL
  wants each turn settled before the next prompt; production still runs Solid
  Queue).

## 0.1.3

- **Ledger: parallel graded gates.** When the model emits several tool calls in
  one step, `settle!` now settles every invocation instead of stopping at the
  first one that needs approval. An ungated call (e.g. a low-risk write) runs
  immediately even when a gated sibling (e.g. a money move) parks for a human —
  it is no longer stranded behind the approval. This changes only *timing*, not
  safety: an unsettled sibling already executed on resume regardless of the
  human's approve/decline, so stopping early only delayed independent work.
  Regression test in `spec/silas/parallel_tool_calls_spec.rb`.

## 0.1.2

- **Security (email channel scaffold): approvals no longer go to the session
  initiator.** The generated `Agent::Channels::Email#deliver_approval` mailed the
  approve link to `email["from"]` — the address that started the session, which
  for a support agent is the customer, letting them approve their own gated
  request. It now routes to a configured operator (`SILAS_APPROVER_EMAIL`) and
  fails closed (sends nothing) if unset. The Slack scaffold was unaffected (its
  card posts to the team channel/thread, not the initiator).

## 0.1.1

- **Fix: parallel tool calls.** When the model emitted several tool_use blocks
  in one turn, replay could send a tool_result with no matching tool_use (the
  provider rejects it) and, under a non-serializing queue adapter, double-execute
  the step. The replayed assistant message's tool_use blocks are now
  reconstructed from the settled ledger invocations — every tool_result has a
  matching tool_use by construction — and consecutive tool results are batched
  into a single provider message. Regression test:
  `spec/silas/parallel_tool_calls_spec.rb`.
- **Boot guard: unsafe queue adapter.** Silas now warns at boot if ActiveJob is
  using the in-process Async adapter, which runs continuation retries
  concurrently and breaks exactly-once. Use Solid Queue (production) or `:inline`
  (scripts/demos). See DEPLOY.md.

## 0.1.0

First release. A durable AI agent framework for Rails ("eve without the bill").

- **Durable loop** on Active Job Continuations + Solid Queue — a turn survives
  crash / deploy / `kill -9` and resumes from the last completed step.
  Chaos-gated: 100/100 runs, zero duplicate side effects, byte-identical
  transcripts, on SQLite and Postgres.
- **Exactly-once tool execution** via a transactional ledger (at-most-once with
  in-doubt→human resolution for external effects).
- **Human-in-the-loop approvals** that park at zero compute, resumable from
  Slack buttons, signed email links, or the inbox.
- **`app/agent/` directory convention**: tools (signature = schema), skills
  (progressive disclosure), instructions, schedules (cron → Solid Queue),
  channels (Action Mailbox + Slack), subagents (isolated delegation),
  connections (external MCP servers as tools).
- **Two engines**: `:ruby_llm` (any provider) and `:agent_sdk` (a `claude -p`
  subprocess; API-key auth).
- **Mountable inbox** at `/silas/inbox`: live trace over Turbo Streams, approval
  cards, per-session/agent cost. Deny-by-default.
- **Evals as a deploy gate**: transcript assertions + opt-in LLM rubric, `bin/ci`.
- **Budgets**: cost / token / time caps per turn.
- **Sandbox seam** with a Docker adapter (interim) for untrusted/model code.
- Deploys self-hosted with Kamal to one cheap VPS (see DEPLOY.md).
