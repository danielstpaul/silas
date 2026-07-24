# Changelog

## 0.2.0 (unreleased)

- **Token streaming, end to end.** The engine seam's `&on_event` block — dead
  code since 0.1.0 — is live: the `:ruby_llm` engine streams the model
  response (`chat.complete` with a block; the assembled message is identical
  to the sync path, so durability semantics are untouched), `StepRunner`
  coalesces text deltas into ~10Hz `"silas.delta"` notifications
  (`Silas::DeltaBuffer`) carrying the accumulated text, and two subscribers
  render them: the inbox trace (synchronous Turbo `broadcast_update_to` into a
  stable per-step target — crash-restream overwrites, never duplicates) and
  the `silas:chat` REPL (tokens print as they arrive). Deltas are decoration
  over the authoritative rows: never persisted, never fed to the model, and a
  replayed step emits none. `around_model_call` hooks keep their existing
  contract and can no longer swallow the stream.
- **Onboarding fixes.** The generated `bin/ci` can now actually fail on app
  tests (it silently swallowed them with `|| true`); the generated initializer
  shows every option the next-steps mention (`inbox_auth`, `sandbox`,
  `memory_approval`, `model_prices`, `eval_dir`, `approval_ttl`) and defaults
  to `claude-sonnet-5` instead of handing a first run the most expensive model
  with no budget set; the rescuer's `recurring.yml` entry is now **idempotent
  and environment-aware** (injected under every deployable env block —
  staging included — never blind-appended into whatever block ends the file,
  never duplicated on a re-run); a missing provider API key is caught **at
  boot** with the exact fix (warns in development, raises `BootGuardError` in
  production); and the unsafe Async-adapter warning **raises in production**,
  where running agents on it silently voids the durability contract.
- **Model-call resilience: transient provider errors retry from the
  checkpoint; nothing ever strands in `running`.** Previously a single
  429/529/timeout failed the loop job permanently and invisibly — the turn sat
  in `running` forever with no retry and no signal. Now:
  `resume_errors_after_advancing = false` on the loop job (Active Job
  Continuations otherwise swallow errors raised after a checkpoint and
  self-resume unboundedly, bypassing `retry_on` — verified against activejob
  8.1); transient classes (`RateLimitError`, `OverloadedError`,
  `ServiceUnavailableError`, `ServerError`, Faraday timeouts) retry with
  polynomial backoff + jitter and **resume from the last completed step**;
  exhaustion and permanent rejections (`UnauthorizedError`,
  `PaymentRequiredError`, …) expire pending approvals and fail the turn
  loudly. The rescuer now also sweeps **stranded turns** — a loop job that
  died with an error outside the retry list fails its turn
  (`reason: "job_failed"`) instead of leaving it running forever. Stale
  approval cards can no longer zombie-resume a failed turn (`approve!` /
  `decline!` refuse; `resume_turn!` guards).
- **The inbox now shows the audit trail it exists to provide.** Tool
  `arguments` render for every settled invocation (not just parked ones), a
  failed tool shows its recorded `error` instead of a bare red pill, and
  `approved_by` / `decline_reason` render on settled approvals — who held the
  lever, and why it moved. Active turns gain a **Cancel** button (running
  turns flag for a step-boundary cancel, parked turns cancel immediately),
  and the "N awaiting approval" badge is now a link filtering the session
  list to what needs you (`?pending=1`).
- **Web chat in the inbox.** The session page gains a composer (`POST
  .../sessions/:id/turns`) and the index a start-a-session form (with a named
  agent picker) — the browser is now a first-class conversational surface, not
  just approve/decline. Writes ride `authenticate_write!` exactly like
  approvals; a turn-in-progress renders as an inline alert; web-chat sessions
  stay `channel: nil` ("direct"), so no outbound delivery jobs are enqueued.

- **`approval :once` is now scoped to (tool, arguments), not tool name alone.**
  Name-only matching was a footgun: approving a £5 refund silently
  auto-approved a £5,000 refund later in the same session. Identical repeat
  calls still skip re-approval; different arguments park again. Graded gates
  belong in an approval lambda.
- **The ledger's checkpoint guard moved to `IsolatedExecutionState`** (from
  `Thread.current[]`, which is fiber-local) — it now follows the app's
  configured isolation level exactly like agent scopes, surviving into
  internally-created fibers where the old flag silently vanished. Nested
  ledger transactions now save/restore the guard instead of clearing it (the
  old `ensure` opened a checkpoint-guard hole for the rest of the outer
  transaction).
- **Removed the `:agent_sdk` engine** (the `claude -p` subprocess integration).
  Its differentiating rationale — running on a Claude subscription plan instead
  of API credits — was structurally unreachable: `--bare` was hardcoded and the
  engine raised without `ANTHROPIC_API_KEY` regardless of `config.auth`, so the
  OAuth path could never execute a turn. What remained was a second engine with
  weaker guarantees on every axis (exactly-once only *within* a run,
  `approval :never` tools only, fail-closed on any mid-subprocess kill) that
  made the durability contract conditional. One production path now:
  `:ruby_llm`.
  - `config.engine = :agent_sdk` raises a clear `BootGuardError` at configure
    time. `config.auth` and the `agent_sdk_*` options are warning no-ops for
    this release (hard removal in 0.3) — an existing initializer won't crash.
  - The in-process MCP server (`Silas::Mcp::Server`/`Handler`) **survives the
    cut** — it is the seam for a planned "mount your agent's tools as an MCP
    server" feature — with its own integration spec. Its bind host moved from
    `config.agent_sdk_mcp_host` to `config.mcp_server_host`.
  - New migration drops `silas_turns.cli_session_id` and
    `silas_turns.mcp_token` (the latter was write-only; tokens are minted and
    compared in memory). Run `bin/rails silas:install:migrations db:migrate`.
  - `Silas::Engines::Base.loop_ownership` is gone — every engine executes one
    model call per step under the framework-owned loop. Custom engines that
    merely inherited it are unaffected.

## 0.1.7

- **Memory — graph-shaped, not a graph database.** New `silas_memories` table:
  entity-attributed facts (`subject · attribute · content`) with provenance
  (session/turn) and **supersession** — a new fact about the same
  subject+attribute retires the old one. Two built-ins: `remember`
  (`transactional!`, **approval-gated by default** — the memory card parks in
  your inbox; `config.memory_approval = :never` opts out) and `recall`
  (on-demand subject lookup). Recent memories inject into the instructions
  snapshot (bounded by `config.memory_injection_limit`). Scopes: private
  per-agent or `shared: true` app-wide. Domain memory stays where it belongs —
  your own tables; this is for the fuzzy residue with no natural home. Edges
  are a deliberate not-yet. Upgrade-safe: tools only advertise when the
  migration has run.
- **Handoffs — staff composition without agent chatter.** New `handoff`
  built-in (advertised when `app/agents/` exists): file a self-contained brief
  that starts another named agent's linked session (`parent_session_id`),
  async by default, `await: true` for run-now-and-return-answer.
  `at_most_once!` through the ledger; refuses self-handoffs, unknown targets,
  cycles, and chains deeper than 3. Free-form agent-to-agent conversation
  remains deliberately unblessed.
- `Session#continue(enqueue: false)` for callers that drive the turn
  themselves. New migration: run `bin/rails silas:install:migrations
  db:migrate` on upgrade.

## 0.1.6

- **Named agents — the staff pattern.** An app can now employ several
  top-level agents: `app/agents/<name>/` (instructions.md, agent.yml, tools/,
  skills/), autoloaded under `Agents::<Name>`, started with
  `Silas.agent(:clerk).start(input: ...)`. Sessions are stamped with the
  agent's name and **every turn — including crash resumes — runs under that
  agent's own scope** (tools, skills, instructions, definitions digest), so a
  rescued staff member can never wake up holding another agent's tools. The
  inbox gains per-agent filter chips; `silas:chat` gains `AGENT=name`. The
  root `app/agent` is unchanged and remains the default.
- **Scope switching is now execution-isolated (concurrency fix).**
  `with_agent_scope` previously mutated global config — two Solid Queue
  threads running different agents (or a delegation racing a parallel job)
  could see each other's tools. Scopes now live in
  `ActiveSupport::IsolatedExecutionState` (per-thread *and* per-fiber —
  Falcon-safe), nestable, with the readers (`Silas.agent`, `tool_resolver`,
  `tool_definitions`, `skills`, `definitions_digest`, `instructions_dir`)
  consulting the active scope first. This also fixes a latent bug where a
  crashed *subagent* turn resumed by the rescuer would run under the ROOT
  agent's scope.

- **Approval lambdas get indifferent-access input.** Arguments are stored as
  jsonb (string keys); a lambda writing `input[:amount]` got a silent nil —
  fail-closed for gates written `nil > 50 ? park : approve`, but a silent
  always-approve for the inverse. `input` is now
  `ActiveSupport::HashWithIndifferentAccess`.
- **Brownfield-safe installer.** `silas:install` now leaves an existing
  `config/initializers/ruby_llm.rb` completely untouched (no conflict prompt —
  an accidental Y clobbered production provider config). First generator specs.
- **hermetic integration.** `config.sandbox = Hermetic.gvisor(image: ...)` is
  now a documented, spec-covered path (the companion
  [hermetic](https://github.com/danielstpaul/hermetic) gem: gVisor, Firecracker,
  hosted E2B, or hardened Docker behind one `run` call, with `trust`/`off_host?`
  as first-class axes). `sandbox_enabled?` now honors the configured backend's
  own `enabled?` (a `Hermetic.null` won't advertise `run_code`), and configuring
  a hermetic backend auto-arms its ledger guard — a sandbox exec inside a ledger
  transaction fails loud. No new runtime dependency: Silas only duck-types
  against the seam.

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
