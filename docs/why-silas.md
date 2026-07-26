# Why Silas

## Build agents the way you build Rails apps

Silas is for the same things every modern agent framework is for: a support
desk that actually resolves tickets, an analyst that posts the Monday digest,
an ops copilot in Slack, a back-office agent that chases invoices. An agent is
a directory of plain files — a persona, a data-only config, one file per tool
— and the framework supplies the durable loop, the scheduling, the channels,
the memory, and the operator surface. If you've looked at eve, the authoring
model will feel immediately familiar; that shape is the category's best idea,
and Silas embraces it.

What's different is *where it runs*. Silas isn't a second runtime you stand
beside your app — it's a gem inside the Rails app you already deploy:

- **Your tools are your app.** `Order.find_by!`, `refunds.create!`, your
  service objects, your validations — no RPC layer between the agent and the
  domain, because the agent lives where the domain lives.
- **Your auth is the agent's auth.** The operator inbox mounts as an engine
  and hides behind whatever `current_user` already means. No second dashboard,
  no second login, no second audit domain.
- **Your deploy is the agent's deploy.** One repo, one CI, one Kamal push.
  The durable substrate — a database, Solid Queue, Active Job Continuations —
  is already booted.

## The guarantees go further

Every serious framework makes the loop durable. Silas draws the line a step
past that, and verifies it with a chaos harness that `kill -9`s live agents
hundreds of times per release (zero duplicate effects, byte-identical replay
— [guarantees](guarantees.md)):

- **Exactly-once tool effects.** A `transactional!` tool's database write and
  the ledger's record of it commit in **one transaction**. A crash mid-refund
  leaves exactly one refund row — never two, never zero — with no idempotency
  key required. Only a framework *inside* your app can offer this: an external
  runtime's ledger can never join your database transaction.
- **Ambiguity waits for a person.** The default mode is at-most-once: a crash
  that makes "did it send?" unanswerable parks the call **in doubt** for a
  human verdict instead of re-firing blind. Never double-pay; sometimes ask.
- **Holds cost nothing.** An approval, a question, or a budget breach parks
  the turn at zero compute — the job exits, and clearing it resumes from
  durable rows without re-calling the model.

If your agents only ever read, any durable loop will do. The moment one
touches money, inventory, or anything you'd hate to see happen twice, this is
the difference you'll feel.

## Batteries included

A production operator inbox (live traces, approval cards, audit trail, cost
accounting), approval-gated memory with provenance, deterministic evals as a
deploy gate, Slack and email channels plus a generator for any transport, a
JSON API with SSE, per-turn budgets, replay-safe compaction — shipped in the
gem, not assembled from templates. And one command builds a working agent app
from nothing:

```bash
rails new desk -m https://raw.githubusercontent.com/danielstpaul/silas/main/templates/desk.rb
```

## The honest notes

- **Silas is early** — 0.5.x, and the guarantees are proven by a reproducible
  chaos harness rather than years of production traffic. The contract is
  measured on every release, and it's stated precisely so you know exactly
  what's promised.
- **Rails-only, on purpose.** If your team lives in TypeScript, eve is
  excellent and closer to home — the [comparison](vs-eve.md) is honest about
  that in both directions.
- **Exactly-once applies to effects in your database.** A raw external call
  with no idempotency key of its own gets at-most-once + in-doubt parking —
  strong, but not transactional. Model money as rows (your app probably
  already does) and you get the full guarantee.
- **Inference goes to your configured provider.** Agent state stays in your
  database; prompts still travel to the model you choose.
- **Untrusted code needs a real sandbox.** The built-in Docker seam is
  interim; configure [hermetic](https://github.com/danielstpaul/hermetic) for
  microVM-class isolation before running code you didn't write.

## Try the claim

Run the template, ask for the £64 refund, clear it from the inbox — and while
the turn is resuming, `kill -9` the worker. Restart it. The turn completes
from its last checkpoint, and `Refund.count` is exactly 1. That's the pitch,
reproduced on your laptop in five minutes.
