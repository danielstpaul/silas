# Silas vs eve

> Written **2026-07-26** against **eve 0.27.6** and Silas 0.6.x, from eve's
> published docs and source. Both projects move fast — if you're reading this
> much later, re-verify before deciding.

Silas and eve share the same organising idea: **an agent is a directory of
conventional files** — instructions, one file per tool, skills, schedules,
channels, connections — running on a durable loop. You can build the same
things with either: support desks, scheduled analysts, Slack copilots,
back-office automations. eve is TypeScript-native, built by Vercel on the AI
SDK, and fully self-hostable. Silas is Rails-native, a gem inside your
existing app.

So the honest first cut is simply your stack: **a TypeScript team should use
eve; a Rails team should use Silas.** The rest of this page is for people near
the boundary — and for the differences that go deeper than language.

---

## The comparison

| | Silas | eve (0.27.6) |
|---|---|---|
| **Shape** | A gem in your Rails app — your database, your job queue, your auth, one deploy. | A TypeScript service beside your app, with its own workflow store and deploy. |
| **Authoring** | A directory of plain files. | A directory of plain files — genuinely the same idea. |
| **Durable loop** | Survives `kill -9`, resumes from the last completed step. A `kill -9` harness runs before each release: zero duplicate effects, byte-identical replay, SQLite + Postgres. | Workflow-engine replay; interrupted steps re-run. |
| **Tool-effect semantics** | **Exactly-once** for DB-recorded effects (`transactional!` — effect + ledger in one transaction). Default at-most-once: an ambiguous crash **parks for a human**. | **At-least-once, documented as such** — "make non-idempotent side effects like charges or emails idempotent, or gate them with approval." Dedup is the tool author's job. |
| **Human-in-the-loop** | Parks at zero compute; cleared from inbox, Slack, signed email, or API; parks expire; `ask_question` for the reverse direction. | `needsApproval` on tools. |
| **Operator surface** | A production inbox mounted in your app: live traces, approval cards, audit trail, cost accounting, web chat. | A dev TUI ("not a production chat UI or customer-facing dashboard"); production UIs are assembled from templates. |
| **Memory** | Shipped: approval-gated triples with provenance and supersession. | Deliberately out of scope. |
| **Ecosystem** | Ruby/Rails. | TypeScript + the AI SDK — a much larger ecosystem, with Vercel's distribution behind it. |
| **Channels & integrations** | Slack + email built in; a generator scaffolds any transport. | More first-party surfaces, growing quickly. |
| **Maturity** | Early (0.6.x); the durability contract is chaos-verified by the maintainer before each release, with the results committed. | Weeks old publicly; backed by a platform company, shipping at platform speed. |

---

## Where Silas goes further

**The transaction boundary.** When an agent's consequential action is a row in
your own database — a refund, a balance move, a ledger entry — Silas commits
the effect and the ledger's dedup record **in the same transaction**. Crash
before commit: both roll back. Crash after: the step is skipped on resume.
No idempotency keys, no reconciliation. This isn't about hosting — it's about
*whose transaction it is*: any runtime outside your application database,
self-hosted or not, keeps its "this step ran" record in its own store, and two
stores can't commit atomically. eve's docs draw the same conclusion from the
other side: make your side effects idempotent, or gate them. Silas is the
framework where you don't have to.

**Ambiguity parks.** At-least-once means a crash can re-fire a side effect.
Silas's default is at-most-once with **in-doubt → human**: it never
double-fires, and an ambiguous call waits for a person.

**The operator surface ships.** `mount Silas::Engine` and the inbox exists —
held/working/filed rail, live traces, approval cards, audit trail, cost, web
chat — behind your app's own auth.

**Memory ships.** Approval-gated, with provenance and supersession. eve
reasonably says "bring your own"; Silas ships the batteries.

## Where eve goes further

- **The ecosystem.** TypeScript and the AI SDK are where most of the agent
  world lives — more examples, more integrations, a bigger hiring pool, and
  Vercel's reach.
- **Surface breadth and velocity.** More first-party channels and
  integrations today, with a platform company's release cadence.
- **Sandboxing posture.** Container sandboxes are integral to eve's design.
  Silas ships an interim Docker seam and reaches microVM-class isolation via
  the [hermetic](https://github.com/danielstpaul/hermetic) gem.

---

## Choosing

**Pick Silas** if you're on Rails — your agent's tools are ordinary Ruby
against your own models, the inbox lives behind your auth, and effects your
app records in its own database get exactly-once semantics no external
runtime can match. Especially if your agents move money.

**Pick eve** if you're in TypeScript — it's an excellent framework with the
same authoring model, the ecosystem's momentum, and Vercel behind it.

Near the boundary (a Rails shop with a TS front-of-house, say): decide by
where your consequential side effects live. If they're rows in the Rails
app's database, that's where the agent belongs.

---

*Claims about eve come from its docs and source at 0.27.6, quoted or
paraphrased in good faith; corrections welcome. Silas's numbers are
reproducible from `chaos_host/results/`.*
