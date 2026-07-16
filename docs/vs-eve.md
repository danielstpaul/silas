# Silas vs eve

**Your Rails app is already an agent runtime.**

This is an honest, engineer-to-engineer comparison — not a scorecard that flatters
Silas. Silas is **v0.1, one maintainer, zero external users**. eve is a mature,
in-production managed platform running at real scale with a steady release cadence.
If you are not on Rails, or you want someone else to own the infrastructure, this
document will mostly talk you *out* of Silas. That's on purpose: it's aimed at
exactly one buyer, and it says so.

The point isn't that Silas beats eve across the board — it doesn't. The point is
that for a Rails team already running Postgres and Solid Queue, the durable agent
runtime is **already booted inside your app**. The only new surface to learn is an
`app/agent/` directory of plain files. eve is a platform you adopt; Silas is a gem
you add to the app you already run.

---

## The honest table

| | Silas | eve |
|---|---|---|
| **Where it runs** | Your Rails app — Active Job Continuations + Solid Queue + one Postgres ledger table. No new service to stand up. | A managed cloud platform (durability, sandbox, gateway) you provision and run against. |
| **Durable loop** (survives crash / deploy / `kill -9`) | ✅ Resumes from the last completed step. Chaos-gated: 100/100 `kill -9` cycles, zero duplicate effects, byte-identical replay, on SQLite and Postgres. | ✅ Workflow replay. Proven in production. |
| **Exactly-once consequential actions** | ✅ **Default, for DB-recorded effects.** A `transactional!` tool's effect row and its ledger row commit or roll back in one Postgres transaction. Raw external calls fall back to at-most-once + in-doubt→human. | ◐ At-least-once; the tool author hand-rolls idempotency or gates the call. |
| **Human-in-the-loop approvals** | ✅ Park at **zero compute** — the job exits; approving replays completed work from rows without re-calling the model. Resumable from Slack, signed email links, or the inbox. | ✅ `needsApproval`. |
| **Operator inbox** (live trace + approve + cost) | ✅ Mounts as an engine **inside your own app** at `/silas/inbox`. Deny-by-default. | ◐ Vendor dashboard. |
| **Data location** | Ledger, transcripts, approvals, and cost accounting are rows in **the Postgres you already run**. No vendor cloud routing agent state; no per-run meter. | Agent state lives in the managed platform. |
| **Maturity / adoption** | ❌ v0.1, one maintainer, zero external users. Durability proven by an in-repo chaos harness, **not by production traffic**. | ✅ In production; steady release cadence; real users. |
| **Sandboxing** | ◐ **Interim Docker seam** — weaker than a microVM and **co-located with the ledger and `RAILS_MASTER_KEY`**. Scoped to trusted code you write yourself. | ✅ Real **per-agent microVM**. |
| **Zero-ops** | ❌ You own Postgres, the worker, the pager, uptime, and security. | ✅ One-command managed durability / sandbox / gateway. |
| **Ecosystem** | Ruby — smaller AI ecosystem; the SDKs and hiring live elsewhere. | TypeScript / Python — the agent-tooling lingua franca. |
| **Channels** | ◐ 2: email (Action Mailbox) + Slack. | ✅ More surfaces. |
| **Credential vaulting** | ❌ Rails credentials by hand. | ✅ Managed OAuth / Connect. |
| **Docs / community / examples** | ❌ Nearly none public yet. | ✅ Full. |

Legend: ✅ solid · ◐ partial · ❌ absent. Read the ✅/❌ split honestly — eve owns
the whole right-hand set of rows below the fold, and those are the rows most buyers
check first.

---

## Where Silas genuinely wins

**It's Rails-native, and that's the whole identity.** If you already run Postgres
and Solid Queue, you don't need a new agent platform, because the durable stack is
already running. Active Job Continuations checkpoint each step; Solid Queue enqueues
the resume; one Postgres table is the ledger. The only new thing to learn is the
`app/agent/` directory — tools whose filename is their identity and whose keyword
signature is the schema the model sees, plus markdown skills, instructions,
schedules, and channels as plain files. Ruby-only is the identity here, not an
apology.

**The runtime is your DB and your app.** The operator inbox isn't a separate console
— it's a mountable engine at `/silas/inbox`, deny-by-default, showing a live
step-trace over Turbo Streams, approval cards, and per-session token/cost accounting.
The Approve/Decline buttons call the exact same `approve!`/`decline!` as Slack and
email. Approvals park at **zero compute**: the job exits, and approving enqueues a
fresh one that replays completed work from rows rather than re-calling the model or
re-running tools.

**Control and data-residency, not a cheaper invoice.** The reframe is deliberate.
Self-hosting Silas is not a way to dodge a platform bill — it's that the ledger,
transcripts, approvals, and cost accounting are rows in the Postgres you already run.
No vendor cloud routes your agent data; there's no meter on your runs. The payoff
isn't a smaller invoice — it's that a compliance or data-residency team can run
agents in an environment where a managed cloud simply **isn't allowed**.

> One honest boundary: this keeps the durable state and the operator surface in your
> own Postgres, but **model inference still goes to whatever provider you configure.**
> It's residency for the agent's home and record — not a promise that prompts never
> leave your network.

**Default-safe exactly-once, in your own transaction.** Most tool calls are read-only
or idempotent, and the genuinely dangerous ones are approval-gated anyway — so this
is the closing argument, not the banner. But it's real: a `transactional!` tool's DB
write and its ledger row commit or roll back **in the same Postgres transaction**,
with no idempotency key required — for effects **recorded in your own database**. The
default policy is `at_most_once!` — when a crash makes an execution ambiguous, the run
**parks for a human verdict** instead of guessing (`idempotent!` is the explicit
opt-in to automatic re-runs).

The proof is measured, not asserted. The in-repo chaos harness `kill -9`s a live
agent 100 times per gate: **100/100 completions, zero duplicate side effects,
byte-identical replay**, on both SQLite and Postgres. The refund-desk demo shows the
same guarantee end to end — crash an agent mid-refund and you're left with **exactly
two refund rows, never three, never one.**

---

## Where eve genuinely wins

Be clear-eyed about this. For most buyers, eve is the correct choice.

- **Maturity, proven at real scale.** eve runs in production and has real users and a
  steady release cadence. Silas has a chaos harness and a demo. "Chaos-gated 100/100"
  is a strong internal signal, but it is not the same as production traffic through
  someone else's ledger, and no honest launch should pretend otherwise. For an
  enterprise buyer this alone is often a veto.
- **A real per-agent microVM.** eve gives each agent microVM-class isolation. Silas's
  sandbox today is an **interim Docker seam** — weaker than a microVM, and worse,
  **co-located on the same host as the ledger and your `RAILS_MASTER_KEY`.** A
  container escape lands on the machine holding your secrets and the ledger itself.
  That is why Silas is scoped to **trusted agent code you write yourself**, not
  untrusted or model-generated code, until off-host microVM-class isolation ships.
- **A managed platform / zero-ops.** eve is one command and someone else owns
  durability, the sandbox, and the gateway. Silas means you own Postgres, the worker,
  the pager, uptime, and security. A predictable managed invoice beats SRE time for
  most teams, and if you'd rather someone else ran the infrastructure, eve is the
  honestly better buy.
- **The TS/Python ecosystem.** The AI SDKs, the examples, and the hiring pool live in
  TypeScript and Python. eve is native to that world. Silas is Ruby-only, on purpose
  — which is a feature for a Rails shop and a disqualifier for everyone else.
- **Breadth today.** More channels, managed OAuth credential vaulting, and full public
  docs and examples. eve is simply further along the surface-area curve.

---

## The one case that is un-buyable from eve

There is exactly one guarantee no managed cloud can sell you, and it's the reason
Silas exists:

**A consequential action your app records in its own database — a refund row, a
balance move, a ledger entry — deduped inside your own Postgres transaction.** The
effect row and the dedup ledger row commit or roll back **together**, in your
database, with no idempotency key required. A crash mid-refund leaves exactly two
refund rows, never three, never one. There is no window where the refund exists but
the ledger doesn't, or vice versa.

The honest scope (and it's the point): this holds when the money movement is a **row
in your Postgres**, which for a Rails app whose database is the system of record is
exactly where it lives. For a raw external HTTP call to a third-party API with no
idempotency key of its own, Silas degrades to **at-most-once + in-doubt→human** — it
won't double-fire, but it parks an ambiguous call for a person. Still stronger than
at-least-once; not "transactional exactly-once."

A managed platform structurally can't place that dedup inside a transaction boundary
it doesn't own — the effect is in your database and the platform's ledger is in its
cloud, so the two can't be one atomic commit. And that boundary is precisely the
managed cloud a data-residency-bound buyer is **forbidden from using in the first
place.** For that specific buyer, this is un-buyable from eve at any price — not
because eve is worse, but because eve's entire value is the managed cloud this buyer
can't touch.

The working refund-desk demo (`demo/refund-desk/`) shows it literally.

---

## Pick Silas if

- You're **already on Rails** (Postgres + Solid Queue) and you own your own ops.
- Your agents take **real, money-moving actions your app records in its own
  database**, and you want dedup and the operator surface **inside your own
  transaction boundary and your own app.**
- You have a hard **self-host / data-residency / compliance** reason agent state
  cannot live in a vendor cloud (and you accept that inference still goes to your
  configured model provider).
- The agent runs **trusted code you write yourself**.
- You're comfortable adopting a **v0.1, one-maintainer** project whose durability is
  proven by a chaos harness rather than by production traffic.

## Pick eve if

- You're **not on Rails**, or your team lives in the TypeScript / Python ecosystem.
- You want **zero-ops** — a managed platform to own durability, sandboxing, and the
  gateway so you don't run Postgres, a worker, and a pager.
- You need to run **untrusted or model-generated code** and require real per-agent
  **microVM** isolation today.
- You need **maturity and proof at scale** now — production references, breadth of
  channels, managed credential vaulting, and full public docs.
- A predictable managed invoice is worth more to you than keeping agent state in your
  own database.

---

*Silas is v0.1: one maintainer, zero external users, honestly narrow. This page
claims nothing beyond the current 0.1.1 codebase and the working refund-desk demo. If
that scope doesn't match you, eve is the right call — and this document is happy to
say so.*
