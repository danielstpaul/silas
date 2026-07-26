# Why Silas

## Your Rails app is already an agent runtime.

You already run a database. You already run Solid Queue. On Rails 8.1 you
already have Active Job Continuations. That is the entire durable substrate an
AI agent needs — a place to checkpoint each step, a worker to resume it, and a
table to record what actually happened. Silas is the observation that you
don't need to stand up a second one.

Every agent framework — managed or self-hosted, TypeScript or otherwise — is a
**second runtime beside your app**: its own process, its own durable store,
its own deploy, its own dashboard. Silas is a gem *inside* the app you deploy
every day. The only genuinely new surface is a directory of plain files:

```
app/agent/
  instructions.md   # the persona (ERB, snapshotted once per turn)
  agent.yml         # data-only config: model, limits
  tools/            # one file per tool; the filename IS the identity
    issue_refund.rb #   the keyword signature IS the schema the model sees
  skills/           # markdown playbooks, loaded on demand
  schedules/        # cron frontmatter -> Solid Queue recurring tasks
  channels/         # email + Slack bound to the loop; generate any other
  connections/      # remote MCP servers as <name>.yml
```

One file per tool. No registry, no wiring file, no decorator soup. Add a file,
get a tool. Starting from nothing? One command builds a working agent app —
`rails new desk -m https://raw.githubusercontent.com/danielstpaul/silas/main/template.rb`
— keyless demo included.

Silas is Ruby-only, and this page leans all the way into that. If you're not
on Rails, stop reading — the "Who this is NOT for" section below says so
plainly. But if you *are* on Rails and moving real, money-moving actions
through your app, you are the one buyer for whom the runtime is already
running — and for whom the guarantee at the bottom of this page cannot be
bought from any second runtime, at any price.

---

## The reframe: this is about the transaction boundary, not a cheaper stack

The easy pitch would be "one less service to run." It's true, and it's minor.
The real reasons to keep the agent inside your own app:

- **The ledger, transcripts, approvals, and cost accounting are rows in the
  database you already run** — inside your backup story, your compliance
  story, your `dependent: :destroy` graph, your transaction boundary. No
  second system's durable store to operate, reconcile against, or explain to
  an auditor.
- **The operator surface ships inside your auth.** The inbox is a mounted
  engine, deny-by-default, guarded by whatever `current_user` already means in
  your app — not another dashboard with another login and another audit
  domain.
- **A data-residency team can run this where a second cloud isn't allowed** —
  and even self-hosted second runtimes double the surface they have to
  certify.

One honest boundary, stated up front so the copy never oversells: this keeps
the agent's **durable state and operator surface** in your own database.
**Model inference still goes to whatever provider you configure.** If prompt
residency is your hard requirement, you'd need a self-hosted model behind the
same adapter seam; Silas doesn't pretend the API call isn't happening.

---

## What's actually guaranteed (and how we measured it)

Durability isn't a slide, it's a contract, verified by a chaos harness that
`kill -9`s live agents hundreds of times per release — not by production
traffic Silas doesn't yet have. Current gate: **100/100 completions per mode
across a 295-run release matrix, zero duplicate side effects, byte-identical
transcripts, on SQLite and Postgres** — including runs that crash
mid-compaction, because context compaction is itself a persisted, exactly-once
effect rather than a rebuild-time computation.

- **A turn survives hard process death** — worker `kill -9`, whole-tree
  `kill -9`, SIGTERM deploys — and resumes from the last completed step. This
  was the falsification gate the project had to pass *before a line of the gem
  was written*, not a benchmark bolted on afterward.
- **Approvals park at zero compute.** A run awaiting a human verdict exits the
  worker entirely — no held thread, no polling loop. Approving enqueues a
  fresh job that replays completed work from ledger rows; it never re-calls
  the model or re-runs a settled tool. Parks expire (default 7 days) rather
  than ghosting forever.
- **A live operator inbox mounts inside your own app** at `/silas/inbox`,
  deny-by-default: held/working/filed rail, live token-streaming traces,
  hoisted approval cards, who-cleared-what audit, cost accounting, cancel,
  raise-budget, web chat.
- **Deploys can't corrupt a run.** Instructions are snapshotted per turn; a
  deploy that changes tools or skills mid-turn fails that turn loudly
  (`NondeterminismError`) instead of quietly resuming into a different agent.
- **The rescuer is part of the contract.** Solid Queue marks a dead worker's
  jobs failed and won't retry them on its own; the installer wires a recurring
  `DeadJobRescuerJob` (every 30s). And monitor worker liveness — the rescuer
  can requeue work, it cannot conjure a consumer.

---

## Where this is honestly early

We're not going to bury this. Silas is **0.5.x. One maintainer. Zero external
users.** The durability claims are proven by an in-repo `kill -9` chaos
harness, not by production load — because there is no production load yet.
"Chaos-gated, zero duplicates" is a strong, reproducible claim; it is
explicitly *not* the same thing as "battle-tested at scale," and if you need
the latter today, a bigger-ecosystem framework is the honest answer and you
should use that instead.

There is one inference adapter: `:ruby_llm` (any provider RubyLLM supports),
bound to the library's public single-turn API — Silas's ledger owns tool
execution; the library never runs your tools. One production path, honestly
stated, beats two paths with an asterisk.

We'd rather you find these limits here than in an incident.

---

## Who this is NOT for

Candor buys credibility, so here is who should close this tab:

- **Non-Rails teams.** Silas is Ruby-only by identity, not by accident. The AI
  SDKs, the tooling, and the hiring pool live in TypeScript and Python, and we
  are not fighting for that ecosystem. If you're not already on Rails, the
  runtime isn't booted for you and none of the wedge above applies.
- **Teams running untrusted or model-generated code** without configuring real
  isolation. The built-in sandbox seam is an **interim Docker adapter** —
  weaker than a microVM and co-located with your ledger and
  `RAILS_MASTER_KEY`. The companion gem
  [hermetic](https://github.com/danielstpaul/hermetic) closes this (gVisor /
  Firecracker / hosted, with the trust level and off-host-ness exposed), but
  until you configure it, Silas is scoped to **trusted agent code you write
  yourself** — and we won't pretend otherwise.
- **Teams that want zero-ops.** You own the database, the worker, the pager,
  uptime, and security — same as the rest of your Rails app. If you'd rather a
  platform owned the agent runtime end to end, buy the platform.

If you're still here, you're on Rails, you run your own ops, and you're moving
real money. Good — the last section is for you.

---

## The closing argument: the guarantee no second runtime can sell you

Most tool calls are read-only or idempotent, and the genuinely dangerous ones
are approval-gated anyway. So exactly-once is deliberately the *last* thing we
talk about, not the banner. But for a Rails team already moving consequential
money, it's the reason to pick Silas and the reason it can't be bought
elsewhere.

The scenario no framework outside your database can cover: **a consequential
action your app records in its own database** — issuing a refund, moving a
balance, writing a ledger entry — that must happen **exactly once** across
crashes, deduped **without** an idempotency key from any external service.

Silas gives you that when the effect is a **write to your own database**. A
tool marked `transactional!` commits its effect row and its dedup ledger row
in the **same** transaction:

- **Crash before commit** → both roll back. On resume the tool runs again from
  a clean slate. No orphan effect.
- **Crash after commit** → the ledger row says `completed`. On resume the step
  is skipped. No second effect.

There is no window where the effect exists but the ledger doesn't, or the
reverse — because they're the same transaction — and no idempotency key is
required, because the dedup lives in your database, not in a downstream API.

**The honest asterisk — and it's the whole point of being honest.** This holds
for effects **recorded in your database**. For a Rails app whose database is
the system of record, that's where money actually moves: the refund *is* a
row. But if the consequential effect is a **raw external HTTP call** to a
third-party API with no idempotency key of its own, the guarantee degrades to
**at-most-once with in-doubt → human parking**: Silas will never double-fire
it, but a call left ambiguous by a crash **parks for a person** rather than
being retried blind. Never double-pay; sometimes ask. That's stronger than the
at-least-once other frameworks document — but it is *not* "transactional
exactly-once," and we won't call it that. Model the money as a row in your own
ledger (as serious Rails money apps already do) and you get the full
guarantee.

Here's why no other framework can match it, hosted anywhere: **its record of
"this step ran" lives in its own durable store, and your effect lives in your
database — two systems, never one atomic commit.** A workflow engine beside
your app can retry, log, and reconcile; it cannot make its dedup row and your
refund row commit or roll back as one unit, because it isn't in the
transaction. That's not a vendor limitation. It's physics — and it's the one
line a gem inside your app gets to stand on.

If that's you: run the
[template](https://github.com/danielstpaul/silas/blob/main/template.rb) or the
[playground](../examples/playground), kill the worker mid-refund, restart, and
count the rows.
