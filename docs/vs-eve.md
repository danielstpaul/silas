# Silas vs eve

> Written **2026-07-29** against **eve 0.27.8** (source and shipped docs, not
> marketing) and Silas 0.6.x. Both projects move fast — if you're reading this
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

One framing note, because it keeps this page honest: eve is a platform
company's product, shipping weekly at roughly twenty-five times Silas's source
volume. A surface-area comparison is a race Silas isn't running. What follows
compares the **guarantees and the shape**, which is where the projects
genuinely differ.

---

## The comparison

| | Silas | eve (0.27.8) |
|---|---|---|
| **Shape** | A gem in your Rails app — your database, your job queue, your auth, one deploy. | A TypeScript service beside your app, with its own workflow store and deploy. |
| **Authoring** | A directory of plain files. | A directory of plain files — genuinely the same idea. |
| **Durable loop** | Survives `kill -9`, resumes from the last completed step. A `kill -9` harness (275-run matrix, SQLite + Postgres) is run before each release, results committed to the repo. | Workflow-engine replay; its own docs: "A step interrupted mid-execution re-runs." |
| **Tool-effect semantics** | **Exactly-once** for DB-recorded effects (`transactional!` — effect + ledger in one transaction). Default at-most-once: an ambiguous crash **parks for a human**. | **At-least-once, documented as such** — "make non-idempotent side effects like charges or emails idempotent, or gate them with approval." Dedup is the tool author's job. |
| **Human-in-the-loop** | Parks at zero compute for days; cleared from inbox, Slack, signed email, or API; **approvals expire** (`approval_ttl`); verdicts are compare-and-swap (one card can't be spent twice); `ask_question` for the reverse direction. | `needsApproval` on tools, with typed input requests (options, freeform, display hints — a nicer request shape than Silas's). Approvals have **no expiry**: an unanswered one waits forever. |
| **A message arriving mid-approval** | **Dropped today** — the sender is told delivery succeeded. An honest gap, fix scheduled. | **Held and replayed** after the approval settles — eve is ahead here. |
| **A deploy while work is parked** | The turn **resumes against its own definitions snapshot** — the deploy is invisible to the model, and the drift is instrumented for the operator. | The next turn silently uses the new deployment's instructions, model, and tools — a parked approval can resume into a different agent than the one that asked. |
| **Operator surface** | A production inbox mounted in your app: activity feed, approval cards, audit trail, cost accounting, handoff lineage, web chat — behind your auth. | A capable dev TUI (drives remote deployments: `--url`, `/deploy`, `/connect`) plus frontend SDKs and templates; the production operator surface is assembled by you. |
| **Memory** | Cross-session memory ships: approval-gated triples with provenance and supersession. | `defineState` ships typed **session-scoped** durable state; anything cross-session "belongs in an external store" (its own docs) — integrations and patterns, not a shipped subsystem. |
| **Evals** | Scenario DSL with scripted model decisions running the **real ledger and real tools against real rows**, keyless, as a deploy gate. | A broader harness: `defineEval`, dataset fan-out, gate-vs-soft severity, LLM-as-judge, reporters. eve is ahead on breadth; the difference in kind is that Silas evals exercise the real transactional machinery. |
| **Channels** | Slack + email built in, **routable to named agents**; a generator scaffolds any transport. | More first-party surfaces (Slack, Discord, Teams, Telegram, Twilio, GitHub, Linear, chat SDK), growing quickly. |
| **Ecosystem** | Ruby/Rails. | TypeScript + the AI SDK — a much larger ecosystem, with Vercel's distribution behind it. |
| **Maturity** | Early (0.6.x); pre-1.0, evolving deliberately. | Pre-1.0 and explicit about it: "prefer breaking changes… no legacy fallback logic." Backed by a platform company. |

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
double-fires, and an ambiguous call waits for a person. Everyone has
approved/denied; Silas also has *we don't know, so someone decides*.

**A park is a contract.** Approvals expire rather than ghosting forever, a
verdict can't be spent twice, and a resumed turn is guaranteed to be the same
agent that parked — or it fails loudly rather than continuing as something
else. eve makes the opposite trade on that last point, deliberately: deploys
apply to live sessions. For exploratory agents that's convenient; for an agent
whose parked action a human already approved, Silas treats silently redefining
it as an audit failure.

**The operator surface ships.** `mount Silas::Engine` and the inbox exists —
the feed, approval cards, audit trail, cost, lineage — behind your app's own
auth.

**The trace lives in your database.** Every step, tool call, argument, result,
approval and cost is rows in *your* schema, joinable to the business rows the
agent actually touched. See [traces](traces.md) — the schema is a documented,
versioned interface, not internal bookkeeping.

## Where eve goes further

- **The ecosystem.** TypeScript and the AI SDK are where most of the agent
  world lives — more examples, more integrations, a bigger hiring pool, and
  Vercel's reach.
- **Surface breadth and velocity.** More first-party channels, a fuller evals
  harness, frontend SDKs, session workspaces with file tools, and a platform
  company's release cadence.
- **Deferred input while parked.** A message arriving during an approval is
  held and replayed. Silas currently drops it — the most honest single row on
  this page, and scheduled work.
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

*Claims about eve come from its source and docs at 0.27.8, quoted or
paraphrased in good faith; corrections welcome. Silas's numbers are
reproducible from `chaos_host/results/`.*
