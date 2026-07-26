# Silas vs eve

> **Date-stamped honesty:** written **2026-07-26** against **eve 0.27.6** and
> the Silas 0.5.x codebase, from eve's published docs and source. eve ships
> fast; if you're reading this months later, re-verify before deciding. An
> earlier revision of this page described eve as a managed-cloud platform —
> that was wrong, and this rewrite corrects it.

**What eve is:** Vercel's open-source agent framework (Apache-2.0, TypeScript,
on the AI SDK). Its organising idea is the same as Silas's — **an agent is a
directory of conventional files** (tools, skills, subagents, channels,
connections, schedules, evals). It is **fully self-hostable**: standard server
output, container sandboxes, a Postgres-backed workflow engine, any provider
the AI SDK supports. Only Vercel-specific conveniences (managed connect, the
hosted runs dashboard) are platform-tied. It is weeks old in public, moving
very fast, with Vercel's distribution behind it.

So the comparison is *not* "self-host vs cloud" — both self-host. It's two
frameworks with the same shape and different physics: **eve is a second
runtime you stand beside your app; Silas is a gem inside the app you already
run.** Everything that matters follows from that.

If you are not on Rails, close this tab — eve is excellent and it's the right
call. This page is aimed at exactly one buyer and says so.

---

## The honest table

| | Silas | eve (0.27.6) |
|---|---|---|
| **Shape** | A gem in your Rails app. The runtime is your app: your database, your job queue, your deploy. | A TypeScript service you run beside your app, with its own workflow store and deploy. |
| **Agent definition** | `app/agent/` directory of plain files. | Agent directory of plain files. Same idea — genuinely. |
| **Durable loop** | Survives `kill -9` and resumes from the last completed step. Chaos-gated: 100/100 per mode across a 295-run matrix, byte-identical replay, SQLite + Postgres. | Workflow-engine replay; interrupted steps re-run. |
| **Tool-effect semantics** | **Exactly-once for DB-recorded effects** (`transactional!` — effect + ledger in one transaction). Default `at_most_once!`: an ambiguous crash **parks for a human verdict**. | **At-least-once, documented as such**: "make non-idempotent side effects like charges or emails idempotent, or gate them with approval." No idempotency primitive; the tool author owns dedup. |
| **Human-in-the-loop** | Park at **zero compute**; same `approve!`/`decline!` from inbox, Slack, signed email, JSON API; parks expire rather than ghost; `ask_question` for the reverse direction. | `needsApproval` on tools. |
| **Operator surface** | A production inbox **mounted in your app**: live traces, hoisted approval cards, audit trail, cost accounting, web chat. Deny-by-default. | A **dev TUI** — explicitly "not a production chat UI or customer-facing dashboard." Their answer is a Next.js template you assemble. |
| **Memory** | Approval-gated triples with provenance and supersession, shipped. | "Deliberately outside eve." |
| **Where agent state lives** | Rows in the database your app already runs — inside your transaction boundary. | The workflow engine's store — durable, but a separate system from your app's database. |
| **Ecosystem & language** | Ruby/Rails only, on purpose. | TypeScript + the AI SDK — the agent lingua franca, vastly larger. |
| **Channels** | Slack + email built in; a generator scaffolds any other transport. | More first-party surfaces, more coming weekly. |
| **Distribution & momentum** | One maintainer, zero external users. | Vercel's distribution; thousands of stars within weeks; fast release cadence. |
| **Maturity** | 0.5.x. Guarantees proven by a reproducible chaos harness, **not production traffic**. | Weeks old publicly, but backed by a platform company and moving at platform-company speed. |

---

## Where Silas genuinely wins

**1. The transaction boundary — and no one else can have it.** When your
agent's consequential action is a row in your own database (a refund, a
balance move, a ledger entry — which, for a Rails app that *is* the system of
record, is where money actually lives), Silas commits the effect row and the
ledger's dedup row **in the same database transaction**. Crash before commit:
both roll back, clean resume. Crash after: the ledger says done, the step is
skipped. No idempotency key, no reconciliation job, no window where one exists
without the other.

This survives eve being self-hostable, because it isn't about hosting — it's
about *whose transaction it is*. eve's workflow store is durable, but it is a
different system from your application database; its record of "this step ran"
and your refund row can never commit atomically. eve's own docs draw the
consequence honestly: make your side effects idempotent, or gate them. Silas
is the framework where you don't have to.

**2. The operator surface ships, in production form, inside your app.** Not a
dev TUI, not a template with seven dependencies to assemble: `mount
Silas::Engine` and the inbox exists — held/working/filed rail, live
token-streaming traces, approval cards, who-cleared-what audit, per-session
cost, cancel, raise-budget, web chat. Your auth guards it; your deploy ships
it.

**3. Memory exists.** eve declines it; Silas ships approval-gated triple
memory with provenance and supersession. Reasonable people can prefer eve's
"bring your own" — but if you want the batteries, only one of these has them.

**4. Ambiguity parks instead of guessing.** At-least-once means a crash can
re-fire a side effect; Silas's default is at-most-once with **in-doubt →
human**: it never double-fires, and a call left ambiguous by a crash waits for
a person. Never double-pay; sometimes ask.

## Where eve genuinely wins

- **The ecosystem.** TypeScript, the AI SDK, the examples, the hiring pool,
  and most of the audience. If your team doesn't live in Ruby, nothing above
  matters.
- **Distribution and velocity.** Vercel's reach, weekly surface growth, more
  channels and integrations today, and momentum a one-maintainer gem cannot
  match. Betting on the ecosystem winner is a rational strategy.
- **Sandboxing posture.** Container sandboxes are integral to eve's design;
  Silas's built-in Docker seam is honest-but-interim and scoped to trusted
  code (the hermetic gem closes the gap when configured).
- **Not being 0.5.x with zero users.** eve is young too, but a platform
  company's young is different from a solo maintainer's young. For many
  buyers this row alone decides it.

---

## Pick Silas if

- You're **on Rails**, and your agents take real actions **your app records in
  its own database** — you want the dedup inside your own transaction and the
  operator surface inside your own auth and deploy.
- You want ambiguous side effects to **wait for a person**, not retry blind.
- You want memory and a production inbox **out of the box**.
- You accept an early, one-maintainer project whose guarantees are proven by a
  reproducible chaos harness rather than production traffic.

## Pick eve if

- You're **not on Rails**, or your team lives in TypeScript and the AI SDK.
- You want the biggest ecosystem, the fastest-growing surface area, and
  Vercel-scale distribution behind your framework.
- At-least-once plus your own idempotency keys is an acceptable contract for
  your side effects.
- You'd rather assemble your own operator UI (or use the dev TUI) than mount
  someone else's.

---

*Claims about eve above come from its published docs and source at 0.27.6 and
are quoted or paraphrased in good faith; corrections welcome. Silas's numbers
are reproducible from `chaos_host/results/` in this repo.*
