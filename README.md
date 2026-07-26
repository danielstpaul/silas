<p align="center">
  <img src="https://raw.githubusercontent.com/danielstpaul/silas/main/docs/img/silas-hero-dark.png" width="1600"
       alt="app/agents/analyst/ on the left, a durable turn holding at a signal in the middle, the inbox approval card on the right">
</p>

# Silas — the agent framework for Rails

Durable AI agents as a directory of plain files, inside the app you already
run. Your database is the agent's memory, Solid Queue is its engine room,
Active Job Continuations are its checkpoints — and on that substrate Silas
adds the guarantees the agent category doesn't ship:

- **Tool effects land exactly once.** A `transactional!` tool's effect and the
  ledger's record of it commit in one database transaction — a crash mid-refund
  leaves exactly one refund row, never two, never zero.
- **Consequential calls hold at the signal.** Approval parks the turn at
  **zero compute** — no held thread, no polling — until a person clears it
  from the inbox, Slack, email, or the JSON API. Parks expire rather than
  ghost.
- **Turns survive `kill -9`** and resume from the last completed step with
  byte-identical transcripts — including long conversations, because context
  compaction is itself a replayable, exactly-once effect.

Every number behind those claims is reproducible from the in-repo chaos
harness (`chaos_host/`), which kill -9s live agents hundreds of times per
release: the current gate is 100/100 completions per mode across a 295-run
release matrix, **zero duplicate effects**, byte-identical replay, on SQLite
and Postgres.

For context (2026-07-26, both from primary sources — details and dates in
[Silas vs eve](https://github.com/danielstpaul/silas/blob/main/docs/vs-eve.md)):
eve, the category leader, documents itself as **at-least-once** ("make
non-idempotent side effects idempotent, or gate them with approval"), ships a
dev TUI but no production operator UI, and declines memory. Running your agent
loop in background jobs is easy everywhere — the guarantees are the part you
can't get elsewhere.

## Sixty seconds, no API key

From nothing:

```bash
rails new desk -m https://raw.githubusercontent.com/danielstpaul/silas/main/template.rb
```

Or in the app you already have:

```bash
bundle add silas
```

```bash
bin/rails generate silas:install && bin/rails db:migrate
```

The template builds a working refund desk: `cd desk && bin/dev`, open the
signal board at `localhost:3000`, and paste *"The walnut monitor stand (order
R-1002) arrived cracked."* into the inbox. The £64 refund **holds at the
signal**; clear it from the amber card and the turn resumes exactly where it
stopped — with exactly one refund row in the database. No API key needed: a
scripted stand-in drives the demo through the real tools, real ledger, and
real hold. (`bin/rails silas:doctor` verifies any install end to end.)

## What ships

| Primitive | The surface |
|---|---|
| **Tools** | One file per tool in `app/agent/tools/`; the filename is the identity, the keyword signature of `#call` is the schema the model sees. Three effect modes: `transactional!` · `at_most_once!` · `idempotent!`. |
| **Approvals** | `approval :always` / `:once` / a lambda over the arguments. Same `approve!`/`decline!` from inbox, Slack, signed email links, and the API. |
| **Skills** | Markdown playbooks in `skills/`, loaded on demand; `description:` frontmatter is the routing hint. |
| **Schedules** | `schedules/*.md` (cron frontmatter, body = the turn input) or `.rb` handlers, compiled to Solid Queue recurring tasks. Named agents own their own cron. |
| **Channels** | Slack + email built in; `bin/rails g silas:channel whatsapp` scaffolds any transport — signature-verifying webhook plus the outbound half. |
| **Memory** | Approval-gated triples with provenance and supersession; `remember` parks a card in your inbox before anything persists. |
| **Named agents** | `app/agents/<name>/` — a staff, each with its own tools, skills, schedules, instructions, and digest. |
| **Subagents & handoffs** | Delegation with scoped toolsets; handoffs file a self-contained brief that starts a linked session — exactly-once-guarded, cycle-checked. |
| **Evals** | Scripted model decisions against the **real ledger**; `bin/rails silas:eval` is a deploy gate. |
| **Structured answers** | `final_answer:` schema in agent.yml → `Turn#answer_data` as a Hash, via each provider's native structured-output mode. |
| **Compaction** | Long conversations summarise past the threshold — as a persisted, exactly-once effect, so crash replays stay byte-identical. |
| **ask_question** | The agent parks to ask the operator something; the answer resumes the turn as the tool result. |
| **Budgets** | Per-turn caps on steps, input tokens, dollars, and active wall-clock; a breach **parks** (a human can top up from the inbox), never destroys work. |
| **Operator inbox** | Mounted engine at `/silas/inbox`: web chat, live traces, approval cards, audit trail, cost accounting, cancel. Deny-by-default. |
| **HTTP API** | Everything the inbox can do over JSON at `/silas/api/v1`, plus SSE streaming with `Last-Event-ID` resume. |

## The directory is the agent

```
app/agent/
  instructions.md   # the persona (ERB, snapshotted once per turn)
  agent.yml         # data-only config: model, limits
  tools/            # one file per tool; identity = filename
    issue_refund.rb #   keyword signature = the schema the model sees
  skills/           # markdown playbooks, loaded on demand
  schedules/        # cron frontmatter -> Solid Queue recurring tasks
  channels/         # slack.rb, email.rb — transports bound to the loop
  connections/      # <name>.yml — remote MCP servers, tools namespaced <name>__<tool>
```

```ruby
class Agent::Tools::IssueRefund < Silas::Tool
  description "Refund an order."
  param :amount_pence, :integer, desc: "Amount in pence"
  approval ->(session:, input:) { input[:amount_pence] > 2_500 ? :user_approval : :approved }
  transactional!        # DB-only side effects -> exactly-once, guaranteed

  def call(order_id:, amount_pence:)
    Refund.create!(order_id:, amount_pence:)
    { refunded: order_id }
  end
end
```

```ruby
session = Silas.agent.start(input: "Refund order 42, £12.50")
session.pending_approvals.first.approve!(by: "daniel")
session.continue(input: "Now email the customer.")
```

Or from the terminal — the REPL runs *inside your app*, so tools hit your real
dev database and parked approvals prompt inline:

```
$ bin/rails silas:chat
you> Refund order 42, £12.50
  ✓ lookup_order(order_id: 42)
  ⏸ issue_refund(order_id: 42, amount_pence: 1250) — held at the signal

approval needed — issue_refund(order_id: 42, amount_pence: 1250)
approve? [y]es / [d]ecline / [s]kip> y
agent> Done — £12.50 refunded on order 42.
```

## The durability contract (what's actually guaranteed)

Verified by `chaos_host/bin/chaos` — results in `chaos_host/results/`:

- **A turn survives hard process death** (worker kill -9, whole-tree kill -9,
  SIGTERM deploys) and resumes from the last completed step: 100% completion,
  byte-identical transcripts, on SQLite and Postgres.
- **`transactional!` tools execute exactly once.** The tool's DB writes and the
  ledger row commit or roll back together. Zero duplicates across every chaos
  run — including runs that compact mid-conversation.
- **Other tools are at-most-once by default** — when a crash makes an execution
  ambiguous, the run **parks for a human verdict** instead of guessing
  (`idempotent!` opts into automatic re-runs).
- **Approvals park at zero compute** — the job exits; approving enqueues a
  fresh one that replays completed work from rows, never re-calling the model
  or re-running tools. Parks expire (default 7 days) rather than ghosting.
- **Transient model errors retry from the checkpoint**; exhausted retries and
  permanent rejections fail the turn loudly. A turn can never sit in `running`
  forever: the rescuer also fails turns stranded by a dead loop job.
- **The rescuer is part of the contract.** Solid Queue marks a dead worker's
  jobs failed and nothing retries them; the installer wires
  `Silas::DeadJobRescuerJob` as a recurring task (every 30s). Do not remove it
  — and monitor worker liveness: the rescuer can requeue work, it cannot
  conjure a consumer.
- **Deploys can't corrupt a run**: instructions are snapshotted per turn, and a
  deploy that changes tools/skills mid-turn fails the turn loudly
  (`NondeterminismError`) instead of resuming into a different agent.
- **Compaction can't corrupt a replay**: a summary is produced once, claimed
  compare-and-swap, persisted — never recomputed at rebuild time — so the
  message array a resumed turn sees is byte-identical to the one the crashed
  turn saw.

## Holding the levers

Anything that moves money or is hard to reverse gets an approval policy, and a
held turn costs nothing while it waits. The reverse direction is built in too:
the `ask_question` tool parks the turn to ask the operator something, and their
typed answer resumes it as the tool result. Budget breaches park the same way —
`max_steps`, `max_input_tokens`, `max_cost`, `timeout` (active wall-clock;
held time doesn't count) — and the inbox has a raise-budget button. Cancel is
honored at the next step boundary, so an in-flight model call's work commits
instead of being forfeited. Details:
[approvals & questions](https://github.com/danielstpaul/silas/blob/main/docs/conventions.md) ·
[budgets](https://github.com/danielstpaul/silas/blob/main/docs/budgets.md) ·
[cancellation](https://github.com/danielstpaul/silas/blob/main/docs/cancellation.md).

## Operating it

Mount the engine (the generator does this) and the inbox appears at
`/silas/inbox`: session rail grouped **Held / Working / Filed**, web chat, a
live token-streaming trace, hoisted approval cards, a full audit trail (every
argument, every result, who cleared what and why), cancel, raise-budget, and
per-session cost accounting priced from RubyLLM's model registry. It is
**deny-by-default** — invisible until you wire `config.inbox_auth`.

The same surface over JSON, also deny-by-default:

```sh
curl -X POST .../silas/api/v1/sessions -d "input=Refund order 42, £12.50"
curl .../silas/api/v1/sessions/1?trace=1                # turns + steps + tool calls
curl -X POST .../silas/api/v1/approvals/7/approve       # the same approve! as the inbox
curl -X POST .../silas/api/v1/approvals/9/answer -d "answer=Use the June invoice"
curl -N .../silas/api/v1/sessions/1/stream              # SSE, Last-Event-ID resume
```

And evals gate your deploys: scenarios script the **model's decisions** while
the real ledger runs your real tools, so `assert_parked`, `assert_approved`,
`assert_tool_called times: 1`, and `assert_no_hallucinated_price` assert on a
genuine durable transcript — keyless and deterministic in CI. See
[docs/evals.md](https://github.com/danielstpaul/silas/blob/main/docs/evals.md).

Turns stream live: deltas render over Turbo in the inbox and print in
`silas:chat`, but they're decoration over durable rows — never persisted, never
fed back to the model, absent from replays — so streaming adds zero risk to the
contract.

## Memory & handoffs

Memory is graph-shaped, not a graph database: `subject · attribute · content`
triples with provenance and supersession, private per agent or `shared: true`
for the staff. `remember` is **approval-gated by default** — the memory card
parks in your inbox before anything persists. Your domain data does not belong
here; it belongs in your tables, which your tools already read.

Staff compose through **handoffs, not conversations**: `handoff` files a
self-contained brief that starts a linked session for another named agent
(async, or `await: true`), exactly-once-guarded, cycle-checked. Two models
chatting freely is a cost and audit hazard — deliberately unblessed.

## Sandbox: untrusted code via hermetic

Code execution is off by default (`config.sandbox = :none`). The built-in
`:docker` seam is honest-but-interim; for real isolation the companion gem
[hermetic](https://github.com/danielstpaul/hermetic) drops in —
`c.sandbox = Hermetic.gvisor(image: "python:3.12-slim")` (or Firecracker, or
hosted) — and the `run_code` tool is advertised automatically. Every hermetic
backend exposes its trust level, and the ledger guard refuses sandbox execs
inside a ledger transaction. Until off-host isolation is configured, Silas is
scoped to **trusted code you write yourself**.

## Adapter

Inference is one pluggable seam (`config.adapter`): `:ruby_llm` — any provider
[RubyLLM](https://rubyllm.com) supports — is the default and the production
path, bound to RubyLLM's public single-turn API (Silas's ledger owns tool
execution; the library never runs your tools). Compose resilience via
`config.around_model_call`, or swap in any object responding to
`#execute_step` — the eval harness, the chaos suite, and the template's
keyless demo are all exactly that.

## Requirements & deploy

Rails >= 8.1 (Active Job Continuations) and Solid Queue >= 1.2. Never run
agents on ActiveJob's in-process `:async` adapter — it double-executes
continuation steps; Silas raises in production and `silas:doctor` flags it
everywhere. Deploy notes that came out of the chaos harness (worker liveness,
the rescuer, what never to hand-delete) live in
[DEPLOY.md](https://github.com/danielstpaul/silas/blob/main/DEPLOY.md).

## Docs

Everything below also ships **inside the gem** (`bundle show silas`), and the
installer writes a Claude Code skill (`.claude/skills/silas/SKILL.md`) so a
coding agent building on your app knows these rules without being told.

| | |
|---|---|
| [Tutorial](https://github.com/danielstpaul/silas/blob/main/docs/tutorial.md) | Build the refund desk from nothing, one primitive per chapter. |
| [Channels](https://github.com/danielstpaul/silas/blob/main/docs/channels.md) | Slack, email, and generating your own transport. |
| [Evals](https://github.com/danielstpaul/silas/blob/main/docs/evals.md) | Scripted decisions, real ledger, deploy gates, rubric grading. |
| [Budgets](https://github.com/danielstpaul/silas/blob/main/docs/budgets.md) | Caps, parking, and human top-ups. |
| [Cancellation](https://github.com/danielstpaul/silas/blob/main/docs/cancellation.md) | What cancel means mid-flight. |
| [Connections](https://github.com/danielstpaul/silas/blob/main/docs/connections.md) | Remote MCP servers as `<name>.yml` files. |
| [Configuration](https://github.com/danielstpaul/silas/blob/main/docs/configuration.md) | Every `Silas.configure` option, with defaults. |
| [Conventions](https://github.com/danielstpaul/silas/blob/main/docs/conventions.md) | The contracts the UI and API keep (including held/clear labels). |
| [Why Silas](https://github.com/danielstpaul/silas/blob/main/docs/why-silas.md) | The pitch, and who should close the tab. |
| [Silas vs eve](https://github.com/danielstpaul/silas/blob/main/docs/vs-eve.md) | An honest, date-stamped comparison. |

## Honestly early

One maintainer, zero external users, 0.5.x. The guarantees are proven by a
reproducible chaos harness — 434 specs, a 295-run kill matrix — **not by
production traffic**, because there is no production traffic yet. If you need
battle-tested-at-scale today, buy that; if you're on Rails, moving real money
your app records in its own database, and you want the dedup inside your own
transaction boundary — that's the one thing nobody else sells, and it's why
this exists.

## License

MIT.
