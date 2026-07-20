# Your Rails app is already an agent runtime.

**Silas** turns the Rails app you already run into a durable AI-agent runtime.
Active Job Continuations, Solid Queue, and one Postgres ledger table make every
turn survive `kill -9` and resume from the last completed step — with a live
operator inbox at `/silas/inbox` and park-at-zero human-in-the-loop approvals
holding the big levers. No new service, no managed platform, no per-run meter:
the durable stack is already booted inside your app. The only new surface is the
`app/agent/` directory below.

Honestly early and honestly narrow: **v0.1, one maintainer, zero external
users**, durability proven by an in-repo `kill -9` chaos harness (100/100, zero
duplicate effects, byte-identical replay), and scoped to **trusted code you write
yourself** by default — for untrusted or model-generated code, drop in the
companion gem [hermetic](https://github.com/danielstpaul/hermetic) (gVisor /
Firecracker / hosted sandboxes behind one call, see below). The full pitch
and the honest caveats: [Why Silas](docs/why-silas.md) ·
[Silas vs eve](docs/vs-eve.md).

```
app/agent/
  instructions.md   # the persona (ERB, snapshotted once per turn)
  agent.yml         # data-only config: model, limits
  tools/            # one file per tool; identity = filename
    issue_refund.rb #   keyword signature = the schema the model sees
  skills/           # markdown playbooks, loaded on demand
    triage.md       #   description: frontmatter is the routing hint
```

## Quickstart

```sh
bundle add silas
bin/rails generate silas:install
bin/rails db:migrate
```

```ruby
class Agent::Tools::IssueRefund < Silas::Tool
  description "Refund an order."
  param :amount, :integer, desc: "Pence"
  approval :always      # parks the run; a human approves from your app
  transactional!        # DB-only side effects -> exactly-once, guaranteed

  def call(order_id:, amount:)
    Refund.create!(order_id:, amount:)
    { refunded: order_id }
  end
end
```

```ruby
session = Silas.agent.start(input: "Refund order 42, £12.50")
session.pending_approvals.first.approve!(by: "daniel")
session.continue(input: "Now email the customer.")
```

Or talk to it from the terminal — the REPL runs *inside your app*, so tools hit
your real dev database, and parked approvals prompt inline (the same
`approve!`/`decline!` as the inbox and Slack):

```
$ bin/rails silas:chat
you> Refund order 42, £12.50
  ✓ lookup_order(order_id: 42)
  ⏸ issue_refund(order_id: 42, amount: 1250) — awaiting approval

approval needed — issue_refund(order_id: 42, amount: 1250)
approve? [y]es / [d]ecline / [s]kip> y
agent> Done — £12.50 refunded on order 42.
```

`SESSION=id` resumes an existing session.

## The durability contract (what's actually guaranteed)

Verified by `chaos_host/bin/chaos` — the harness that kill -9s a live agent
hundreds of times per release (results in `chaos_host/results/`):

- **A turn survives hard process death** (worker kill -9, whole-tree kill -9,
  SIGTERM deploys) and resumes from the last completed step: 100% completion,
  byte-identical transcripts, on SQLite and Postgres.
- **`transactional!` tools execute exactly once.** The tool's DB writes and the
  ledger row commit or roll back together. Zero duplicates across every chaos run.
- **Other tools are at-least-once within one step** — and when a crash makes an
  execution ambiguous, the default `at_most_once!` policy **parks the run for a
  human verdict** instead of guessing (`idempotent!` opts into automatic re-runs).
- **Approvals park at zero compute** — the job exits; approving enqueues a fresh
  one that replays completed work from rows, never re-calling the model or
  re-running tools. Parks expire (default 7 days) rather than ghosting forever.
- **The rescuer is part of the contract.** Solid Queue marks a dead worker's
  jobs failed and nothing retries them; the installer wires
  `Silas::DeadJobRescuerJob` as a recurring task (every 30s). Recovery time ≈
  `SolidQueue.process_alive_threshold` + that cadence. Do not remove it.
- **Deploys can't corrupt a run**: instructions are snapshotted per turn, and a
  deploy that changes tools/skills mid-turn fails the turn loudly
  (`NondeterminismError`) instead of resuming into a different agent.

## Engines

Inference is one pluggable seam (`config.engine`):

- `:ruby_llm` — API-key auth via [RubyLLM](https://rubyllm.com); any provider it
  supports. Canonical, production mode. Compose resilience via
  `config.around_model_call`.
- `:agent_sdk` — a `claude -p` subprocess runs the whole turn, calling back into
  your tools over an in-worker HTTP MCP endpoint whose `tools/call` goes through
  the same Ledger. Always `--bare` (API-key auth only; the boot guard raises if
  OAuth is configured with `ANTHROPIC_API_KEY` present, and if the key is missing
  in api_key mode). v1 is honestly weaker than `:ruby_llm`: exactly-once *within*
  a run, `approval :never` tools only, and fail-closed on a mid-subprocess kill.

## Sandbox: run untrusted code with hermetic

The sandbox is a second pluggable seam (`config.sandbox`). Built-in adapters are
`:none` (default — code execution off) and `:docker` (hardened container,
honest-but-interim). For real isolation, the companion gem
[**hermetic**](https://github.com/danielstpaul/hermetic) drops straight in:

```ruby
# Gemfile: gem "hermetic"   (zero runtime deps)
Silas.configure do |c|
  c.sandbox = Hermetic.gvisor(image: "python:3.12-slim")     # or .docker /
  # .firecracker(kernel:, rootfs:) / .hosted(:e2b, api_key:) # pick your strength
end
```

That's the whole integration. When a sandbox is configured and enabled, the
`run_code` tool is advertised to the model automatically (`at_most_once!` — an
exec is an external effect). Two properties carry through the seam:

- **The trust axis is visible**: every hermetic backend exposes `trust`
  (`:vendor`/`:remote`/`:vm`/`:host`) and `off_host?`, so you can refuse to run
  untrusted code on the box that holds your `RAILS_MASTER_KEY` — pair any local
  backend with `executor:` to push execution to a dedicated sandbox host.
- **The ledger guard is auto-armed**: configuring a hermetic backend loads its
  Silas shim, so a sandbox exec attempted inside a ledger transaction fails loud
  (sandbox-backed tools must be `at_most_once!`, never `transactional!`).

## Named agents: the staff pattern

One app can employ several agents, each with its own room:

```
app/agents/
  reader/            # Silas.agent(:reader).start(input: "...")
    instructions.md
    agent.yml        # model, limits — same keys as the root agent
    tools/
    skills/
  clerk/
    ...
```

Sessions are stamped with the agent's name; every turn — including crash
resumes — runs under that agent's own tools, skills, instructions, and
definitions digest. The inbox filters by agent; `bin/rails silas:chat
AGENT=clerk` chats with one staff member. The root `app/agent/` remains the
default agent, unchanged. (Subagents stay a root-agent delegation feature;
scope switching is execution-isolated, so concurrent jobs running different
agents never cross wires.)

## Memory & handoffs

Silas memory is **graph-shaped, not a graph database**: facts as
`subject · attribute · content` triples with provenance and supersession
("author:jane · report_format: prefers CSV" — a new value retires the old).
The `remember` tool is **approval-gated by default** — the memory card parks
in your inbox before anything persists; `recall` digs deeper than the few
recent memories injected into each turn. Private per agent, or `shared: true`
for the whole staff. Your *domain* data does not belong here — it belongs in
your own tables, which your tools already read; memory is for the fuzzy
residue with no natural home.

Staff compose through **handoffs, not conversations**: `handoff` files a
self-contained brief that starts a linked session for another named agent
(async, or `await: true` for an answer), exactly-once-guarded, cycle-checked.
Two models chatting freely is a cost and audit hazard — deliberately
unblessed.

## Triggers

An agent is reached by more than a method call:

- **`schedules/`** — `app/agent/schedules/*.md` (cron frontmatter, body = the turn
  input) or `*.rb` handlers. `bin/rails silas:schedules` compiles them into
  Solid Queue recurring tasks. A scheduled run is a normal durable turn.
- **`channels/`** — `app/agent/channels/*.rb` bind email (Action Mailbox) and
  Slack to the loop. A new thread starts a session, a reply continues it, and
  approvals render as Slack buttons / signed email links that call the same
  `approve!`/`decline!`. Outbound delivery is idempotent and off the durable loop.

## The inbox

Mount the engine (the generator does this) and a live inbox appears at
`/silas/inbox`: a session list, a live step-trace that streams over Turbo
Streams as the agent runs, approval cards whose Approve/Decline buttons call the
exact same `approve!`/`decline!` as Slack and email, and per-session token/cost
accounting. It's **deny-by-default** — invisible until you wire auth:

```ruby
Silas.configure do |c|
  # Devise-compatible: the lambda DENIES by rendering; passes by not rendering.
  c.inbox_auth = ->(controller) { controller.head :not_found unless controller.current_user&.admin? }
  # c.inbox_public_read = true   # public read-only demo; approve/decline stay gated
  # c.model_prices["your-model"] = { in: 300, out: 1500 }  # microcents / 1k tokens
end
```

Turbo streaming activates automatically when the host has `turbo-rails` (every
default Rails app does); without it the trace falls back to a polling refresh.
The gem itself takes no turbo dependency.

## Requirements

Rails >= 8.1 (Active Job Continuations) and Solid Queue >= 1.2 for the
durability contract. macOS dev note: Solid Queue forks + pg need
`PGGSSENCMODE=disable OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`.

## License

MIT.
