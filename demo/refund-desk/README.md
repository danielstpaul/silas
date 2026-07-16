# Silas demo — Nimbus Coffee refund desk

A working [Silas](../..) agent that handles customer refund requests end to
end, showing the three things Silas is actually for:

1. **An agent is a directory.** The whole agent is the files under
   [`app/agent/`](app/agent) — instructions, a model, and two tools. No wiring.
2. **Money moves exactly once.** `issue_refund` writes the refund row *and* the
   ledger row in one transaction. A crash mid-refund can't double-pay or vanish.
3. **A human holds the big lever.** Refunds over £50 pause at zero compute and
   wait for a person to approve them in an in-app inbox — the trace, the cost,
   and the Approve/Decline buttons all render at `/silas/inbox`.

## What you'll see

Two customers message the desk:

| Customer | Order | Amount | What happens |
|----------|-------|--------|--------------|
| Casey    | 1042  | £38    | Under the £50 gate → refund issued automatically → turn **completed**. |
| Jordan   | 2087  | £120   | Over the gate → refund **parked** for a manager → turn **waiting**. |

The inbox shows Casey done and Jordan awaiting approval. Click **Approve** on
Jordan's refund and the turn resumes, issues the £120 refund, and completes —
leaving exactly two refund rows. Never three, never one.

## The agent, in full

```
app/agent/
  agent.yml               # model + per-turn budget caps
  instructions.md         # the system prompt
  tools/
    lookup_order.rb       # read-only: fetch an order
    issue_refund.rb       # transactional! + approval gate: the money move
```

The whole approval-gate behaviour is these three lines in
[`tools/issue_refund.rb`](app/agent/tools/issue_refund.rb):

```ruby
transactional!                                   # refund row + ledger row commit together
approval ->(session:, input:) { input["amount"].to_i > 5000 ? :user_approval : :approved }
```

`transactional!` is the exactly-once guarantee; the `approval` lambda is the
human-in-the-loop gate. Everything else is a plain Rails tool.

## Run it

This demo is a set of files you drop into a Rails 8.1 app that has the Silas
gem installed and mounted. Assuming a fresh app:

```bash
# 1. Add Silas (path or git) and run its install generator
bundle add silas                    # or: gem "silas", path: "../silas"
bin/rails generate silas:install    # migration + app/agent skeleton + engine mount

# 2. Copy this demo's files over the skeleton
cp -r demo/refund-desk/app/agent/*                    app/agent/
cp    demo/refund-desk/app/models/*.rb                app/models/
cp    demo/refund-desk/db/migrate/*                   db/migrate/
cp    demo/refund-desk/db/seeds.rb                    db/seeds.rb
cp    demo/refund-desk/config/initializers/silas.rb   config/initializers/silas.rb
cp    demo/refund-desk/config/initializers/ruby_llm.rb config/initializers/ruby_llm.rb
cp    demo/refund-desk/script/demo.rb                 script/demo.rb
rm -f app/agent/tools/example_tool.rb                 # drop the generator's placeholder tool

# 3. Migrate + seed the store
bin/rails db:migrate db:seed

# 4. Point RubyLLM at your key (config/initializers/ruby_llm.rb reads this)
export ANTHROPIC_API_KEY=sk-ant-...

# 5. Populate the inbox to the decision point
bin/rails runner script/demo.rb

# 6. Start the server and open the inbox
bin/rails server
open http://localhost:3000/silas/inbox
```

Approve Jordan's refund in the inbox; the turn resumes and completes.

> The demo runs on the synchronous `:inline` queue adapter, set in the copied
> `config/initializers/silas.rb`. Don't run this demo on Rails' dev-default Async
> adapter — it double-executes steps and breaks exactly-once (Silas warns at
> boot). Production uses Solid Queue — see [`silas/DEPLOY.md`](../../DEPLOY.md).

## Why the demo config differs from production

Two settings in this demo are deliberately **not** how you'd run in production
(both are annotated in the files):

- **`ActiveJob::Base.queue_adapter = :inline`** (set in the copied
  `config/initializers/silas.rb`). The demo runs each turn synchronously in one
  process. Rails' dev default — the in-process **Async** adapter — is unsafe for
  Silas: it runs continuation retries on a thread pool *concurrently* with the
  original job, which double-executes steps and breaks exactly-once. Silas warns
  at boot if it detects the Async adapter. **Production uses Solid Queue** (see
  [`silas/DEPLOY.md`](../../DEPLOY.md)).
- **`config.inbox_auth = ->(_) {}`** opens Approve/Decline to anyone on the local
  server. Production gates this on your own auth.

## Durability — the kill-the-server test

The demo above runs `:inline` for a clean single-process story. The *durability*
claim needs the real runtime: **Solid Queue + `isolate_steps: true`** (the
default), where every step is its own durable checkpoint.

To see a turn survive a hard kill:

```bash
# Terminal 1 — run the worker
bin/jobs

# Terminal 2 — enqueue a turn, then kill -9 the worker mid-flight
bin/rails runner 'Silas.agent.start(input: "Jordan here, order 2087, cracked — refund please").tap { |s| Silas::AgentLoopJob.perform_later(s.turns.first.id) }'
# ...while it is running a step, in another terminal:
kill -9 $(pgrep -f solid_queue)

# Restart the worker — the turn resumes from the last committed step,
# re-running no completed step and re-issuing no refund.
bin/jobs
```

The rigorous version of this is the in-repo chaos gate
([`chaos_host/`](../../chaos_host)): **100/100 `kill -9` cycles, zero duplicate
effects, byte-identical replay**, on SQLite and Postgres, run on every release.

## How the exactly-once guarantee holds

`issue_refund` is `transactional!`, so its effect and its ledger row commit in
one database transaction:

- **Crash before commit** → both roll back. On resume the tool runs again from a
  clean slate. No orphan refund.
- **Crash after commit** → the ledger row says `completed`. On resume the step is
  skipped. No second refund.

There is no window where the refund exists but the ledger doesn't, or vice
versa — that's what "exactly once" means here. The refund is a row in *your*
database, so its dedup ledger row commits in the same transaction — no external
idempotency key required. (A raw external call to an un-keyed payments API would
instead be at-most-once with in-doubt → human parking; model the money movement
as a row and you get the full guarantee.)
