# Why Silas

## Your Rails app is already an agent runtime.

You already run Postgres. You already run Solid Queue. On Rails 8.1 you already
have Active Job Continuations. That is the entire durable substrate an AI agent
needs — a place to checkpoint each step, a worker to resume it, and a table to
record what actually happened. Silas is the observation that you don't need to
buy a second one.

There is no new service to stand up, no control plane to point at, no per-run
meter. The durable agent stack is already booted inside the app you deploy every
day. The only genuinely new surface is a directory of plain files: `app/agent/`.

```
app/agent/
  instructions.md   # the persona (ERB, snapshotted once per turn)
  agent.yml         # data-only config: model, limits
  tools/            # one file per tool; the filename IS the identity
    issue_refund.rb #   the keyword signature IS the schema the model sees
  skills/           # markdown playbooks, loaded on demand
    triage.md
  schedules/        # cron frontmatter → Solid Queue recurring tasks
  channels/         # email (Action Mailbox) + Slack bound to the loop
```

One file per tool. The filename is how the model addresses it; the Ruby keyword
signature is the schema the model sees. No registry, no wiring file, no
decorator soup. Add a file, get a tool.

Silas is Ruby-only, and this page leans all the way into that. If you're not on
Rails, stop reading — this isn't for you, and the "Who this is not for" section
below says so plainly. But if you *are* on Rails and moving real, money-moving
actions through your app, you are the one buyer for whom the runtime is already
running and for whom this is genuinely un-buyable from a managed cloud. That's
the whole thesis.

---

## The reframe: this is about control, not a cheaper invoice

The easy pitch would be "self-host and dodge the platform bill." That pitch is
weak and we're not going to make it. Self-hosting means *you* own Postgres, the
worker, the pager, uptime, and security. For a lot of teams a predictable
managed invoice is the better buy, and we'll say that out loud below.

The real reason to keep the runtime in your own app is **control and data
residency**, not cost:

- The ledger, the transcripts, the approval records, and the per-run cost
  accounting are **rows in the Postgres you already run**. No vendor cloud sits
  in the path of your agent's state. No meter counts your runs.
- A compliance or data-residency team can run agents in an environment where a
  managed agent cloud simply **isn't allowed to operate**. That's not a
  discount — it's the difference between "can deploy this" and "cannot."

One honest boundary, stated up front so the copy never oversells: this keeps the
agent's **durable state and operator surface** in your own Postgres. **Model
inference still goes to whatever provider you configure.** So it's data
residency for the agent's home and system of record — the ledger, the
transcript, the approvals, the cost rows — not a promise that your prompts never
leave your network. If prompt residency is your hard requirement, you'd need a
self-hosted model behind the same engine seam; Silas doesn't pretend the API
call to your model provider isn't happening.

---

## What's actually guaranteed (and how we measured it)

Durability isn't a slide, it's a contract, and it's verified by a chaos harness
that `kill -9`s a live agent hundreds of times per release — not by production
traffic Silas doesn't yet have.

- **A turn survives hard process death** — worker `kill -9`, whole-process-tree
  `kill -9`, SIGTERM deploys — and resumes from the last completed step. The
  gate result: **100/100 kill cycles, zero duplicate side effects,
  byte-identical transcripts, on both SQLite and Postgres.** This was the
  falsification gate the project had to pass *before a line of the gem was
  written*, not a benchmark bolted on afterward.
- **Approvals park at zero compute.** A run awaiting a human verdict exits the
  worker entirely — no held thread, no polling loop burning a slot. Approving
  enqueues a fresh job that replays completed work from ledger rows; it never
  re-calls the model or re-runs a settled tool. Parks expire (default 7 days)
  rather than ghosting forever.
- **A live operator inbox mounts inside your own app** at `/silas/inbox`: a
  session list, a step-trace that streams over Turbo as the agent runs, approval
  cards whose Approve/Decline buttons call the *same* `approve!`/`decline!` as
  Slack and email, and per-session token/cost accounting. It's
  deny-by-default — invisible until you wire auth.
- **Deploys can't corrupt a run.** Instructions are snapshotted per turn; a
  deploy that changes tools or skills mid-turn fails that turn loudly
  (`NondeterminismError`) instead of quietly resuming into a different agent.
- **The rescuer is part of the contract.** Solid Queue marks a dead worker's
  jobs failed and won't retry them on its own, so the installer wires a
  recurring `DeadJobRescuerJob` (every 30s). Recovery time ≈
  `process_alive_threshold` + that cadence. It's not optional; don't remove it.

That's the headline. The runtime is your DB and your app, with an in-app
operator inbox and park-at-zero human-in-the-loop. Everything below is the
closing argument for one specific buyer.

---

## Where this is honestly early

We're not going to bury this. Silas is **v0.1. One maintainer. Zero external
users.** The durability claims are proven by an in-repo `kill -9` chaos harness,
not by production load — because there is no production load yet. "Chaos-gated
100/100" is a strong, reproducible claim; it is explicitly *not* the same thing
as "battle-tested at scale," and if you need the latter today, a proven managed
platform is the honest answer and you should buy that instead.

The `:agent_sdk` engine (a `claude -p` subprocess that calls back into your
tools over an in-worker MCP endpoint) is **API-key auth only** — there is no
subscription-billing path, and the boot guard raises if you try to configure one.
It's honestly weaker than the canonical `:ruby_llm` engine: exactly-once *within*
a run, `approval :never` tools only, fail-closed on a mid-subprocess kill.
`:ruby_llm` (API-key auth via RubyLLM, any provider it supports) is the
production mode.

We'd rather you find these limits here than in an incident.

---

## Who this is NOT for

Candor buys credibility, so here is who should close this tab:

- **Non-Rails teams.** Silas is Ruby-only by identity, not by accident. The AI
  SDKs, the tooling, and the hiring pool live in TypeScript and Python, and we
  are not fighting for that ecosystem. If you're not already on Rails with
  Postgres and Solid Queue, the runtime isn't booted for you and none of the
  wedge above applies.
- **Teams running untrusted or model-generated code.** Today's sandbox is an
  **interim Docker seam** — weaker than a microVM and **co-located on the same
  host as the ledger and your `RAILS_MASTER_KEY`**. A container escape lands on
  the machine holding your secrets and the ledger itself. So Silas is scoped to
  **trusted agent code you write yourself**, not arbitrary untrusted or
  model-authored code, until off-host, microVM-class isolation ships. If your
  threat model requires running code you don't trust, this is the wrong tool
  right now and we won't pretend otherwise.
- **Teams that want a managed platform.** Self-hosting means you own Postgres,
  the worker, the pager, uptime, and security. If you'd rather someone else ran
  the durability, the sandbox, and the gateway for a predictable invoice, a
  managed agent platform is the genuinely better buy. Silas is explicitly not
  for zero-ops teams.

If you're still here, you're on Rails, you run your own ops, and you're moving
real money. Good — the last section is for you.

---

## The closing argument: the guarantee no managed cloud can sell you

Most tool calls are read-only or idempotent, and the genuinely dangerous ones
are approval-gated anyway. So exactly-once is deliberately the *last* thing we
talk about, not the banner. But for a Rails team already moving consequential
money, it's the reason to pick Silas and the reason it can't be bought elsewhere.

The scenario a managed cloud structurally cannot cover: **a consequential action
your app records in its own database** — issuing a refund, moving a balance,
writing a ledger entry — that must happen **exactly once** across crashes,
deduped **without** an idempotency key from any external service.

Silas gives you that when the effect is a **write to your own Postgres**. A tool
marked `transactional!` commits its effect row and its dedup ledger row in the
**same** transaction:

- **Crash before commit** → both roll back. On resume the tool runs again from a
  clean slate. No orphan effect.
- **Crash after commit** → the ledger row says `completed`. On resume the step
  is skipped. No second effect.

There is no window where the effect exists but the ledger doesn't, or the
reverse — because they're the same transaction — and no idempotency key is
required, because the dedup lives in your database, not in a downstream API.

**The honest asterisk — and it's the whole point of being honest.** This
exactly-once guarantee holds for effects **recorded in your Postgres**. For a
Rails app whose database is the system of record, that's where the money
actually moves: the refund *is* a row. But if the consequential effect is a
**raw external HTTP call** to a third-party API that offers no idempotency key
of its own, the guarantee degrades to **at-most-once with in-doubt → human
parking**: Silas will never double-fire it, but a call left ambiguous by a crash
**parks for a person** rather than being retried blind. Never double-pay;
sometimes ask. That's stronger than the at-least-once most frameworks give you —
but it is *not* "transactional exactly-once," and we won't call it that. Model
the money movement as a row in your own ledger (as most serious Rails money apps
already do) and you get the full guarantee; reach out to an un-keyed external API
and you get at-most-once-plus-park.

The working refund-desk demo shows the full-guarantee case literally. Two
customers message the desk; a £120 refund is over the £50 gate, so it **parks
for a manager** at zero compute while a £38 refund completes automatically.
Approve the parked one in the inbox, `kill -9` the worker mid-refund, restart —
and the store ends with **exactly two refund rows. Never three, never one.**
That's what "exactly once" means when the effect is a row inside your
transaction boundary.

Here's why a managed cloud can't match it at any price: its dedup can't live
inside a transaction boundary it doesn't own. Your Postgres transaction is
*yours*. A vendor sitting outside your database can retry, log, and reconcile,
but it cannot make its dedup row and your effect row commit or roll back as one
atomic unit — because it isn't in the transaction. And for the data-residency
buyer, that managed cloud is the one place they're **forbidden from sending
agent data in the first place.**

That's the narrow, honest claim: for a Rails team, moving real money it records
in its own database, with a hard data-residency reason to keep agent state in
that database, running trusted code — Silas is **un-buyable from a managed cloud
at any price**, because the guarantee only exists inside a transaction boundary
the cloud doesn't own and an app the compliance team is allowed to run.

If that's you, clone the [refund-desk demo](../demo/refund-desk), kill the
worker mid-refund, and count the rows.
