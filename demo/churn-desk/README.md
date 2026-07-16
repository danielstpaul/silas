# Silas flagship demo — the Churn Desk

A [Silas](../..) support-ops agent for **Meridian**, a B2B analytics SaaS. A
support engineer talks to it in Slack; its tools **are Meridian's own
ActiveRecord models**. It shows the whole reason Silas exists, in one flow:

1. **Your app is already the runtime.** The agent lives in [`app/agent/`](app/agent);
   its tools read and write your real `Customer` / `Charge` / `Credit` tables. No
   second system anywhere.
2. **A graded gate.** Low-risk actions apply immediately; consequential ones
   **park at zero compute** for a human in an operator inbox mounted *inside your
   app* at `/silas/inbox`.
3. **Exactly-once money, proven under `kill -9`.** The credit is a row in your
   Postgres, so its effect row and its dedup ledger row commit in one
   transaction. Crash the worker mid-write and the store lands on **exactly one
   credit row — never two.**

## The scenario

> **@silas** acme (acme.io) emailed — they were double-charged £240 on the Team
> plan in May and are threatening to churn. Credit them £240 for the duplicate
> and extend their trial 14 days as goodwill.

The agent looks Acme up, reads their charges (it spots the two identical £240
charges on the same day), then acts on the graded gate:

| Tool | Risk | What happens |
|------|------|--------------|
| `find_customer`, `recent_charges` | read | run immediately |
| `extend_trial` (+14 days) | low-risk write | **applies immediately** — no approval |
| `issue_credit` (£240) | money, over £50 | **parks** for a manager in `/silas/inbox` |
| `cancel_subscription` | destructive | **always parks** for a manager |

The trial extension lands right away; the £240 credit waits. Approve it in the
inbox and the turn resumes and issues the credit — exactly once.

## The agent, in full

```
app/agent/
  agent.yml                    # model + per-turn budget caps
  instructions.md              # the support-ops persona
  channels/slack.rb            # @mention → session; replies + approval card in-thread
  tools/
    find_customer.rb           # read: look up by domain or name
    recent_charges.rb          # read: recent charges
    extend_trial.rb            # ungated write (low-risk goodwill)
    issue_credit.rb            # transactional! + approval gate (> £50): the money move
    cancel_subscription.rb     # transactional! + approval :always: destructive
```

The graded gate is just declarations on each tool — e.g.
[`tools/issue_credit.rb`](app/agent/tools/issue_credit.rb):

```ruby
transactional!                                   # the Credit row + ledger row commit together
approval ->(session:, input:) { input["amount_pence"].to_i > 5000 ? :user_approval : :approved }
```

## Run it

Drop these files into a Rails 8.1 app with Silas installed (needs
**silas ≥ 0.1.3** for the parallel graded-gate behaviour):

```bash
# 1. Add Silas and run its install generator
bundle add silas                    # or: gem "silas", path: "../silas"
bin/rails generate silas:install

# 2. Copy this demo's files over the skeleton
cp -r demo/churn-desk/app/agent/*                     app/agent/
cp    demo/churn-desk/app/models/*.rb                 app/models/
cp    demo/churn-desk/db/migrate/*                    db/migrate/
cp    demo/churn-desk/db/seeds.rb                     db/seeds.rb
cp    demo/churn-desk/config/initializers/silas.rb    config/initializers/silas.rb
cp    demo/churn-desk/config/initializers/ruby_llm.rb config/initializers/ruby_llm.rb
cp    demo/churn-desk/script/demo.rb                  script/demo.rb
rm -f app/agent/tools/example_tool.rb                 # drop the generator placeholder

# 3. Migrate + seed Meridian
bin/rails db:migrate db:seed

# 4. Point RubyLLM at your key (config/initializers/ruby_llm.rb reads this)
export ANTHROPIC_API_KEY=sk-ant-...

# 5. Populate the inbox to the decision point
bin/rails runner script/demo.rb

# 6. Start the server and open the inbox
bin/rails server
open http://localhost:3000/silas/inbox
```

Approve the £240 credit in the inbox; the turn resumes and applies it.

> Runs on the synchronous `:inline` adapter (set in the copied `silas.rb`). Don't
> run this on Rails' dev-default Async adapter — it double-executes steps and
> breaks exactly-once (Silas warns at boot). Production uses Solid Queue — see
> [`silas/DEPLOY.md`](../../DEPLOY.md).

## Slack

The [`channels/slack.rb`](app/agent/channels/slack.rb) binding makes the desk
@mentionable in a team channel; replies and the Approve/Decline card post back
into the same thread (operator-visible, so approvals never reach a customer).
Wire `credentials.silas.slack.{signing_secret,bot_token}` and point Slack's Event
+ interactivity URLs at the mounted engine. Without Slack, drive it with
`script/demo.rb` and the web inbox exactly as above.

## Durability — the kill-the-server test

The `:inline` run above is single-process. The durability claim needs the real
runtime: **Solid Queue + `isolate_steps: true`** (the default), a separate
`bin/jobs` worker. Enqueue the scenario, approve the credit, `kill -9` the worker
mid-write, restart — the turn resumes from the last committed step and the store
ends with **exactly one credit row**. The rigorous version is the in-repo chaos
gate ([`chaos_host/`](../../chaos_host)): 100/100 `kill -9` cycles, zero duplicate
effects, byte-identical replay.

## Why exactly-once holds (and its honest edge)

`issue_credit` is `transactional!`: the `Credit` row and its ledger row commit or
roll back **together**. Crash before commit → both roll back, resume re-runs it
(one row). Crash after commit → the ledger says `completed`, resume skips it (one
row). No idempotency key needed, because the dedup lives in *your* database.

That guarantee holds because the credit **is a row in your Postgres**. If instead
you called a raw external payments API with no idempotency key of its own, the
honest guarantee degrades to **at-most-once with in-doubt → human parking** —
Silas never double-fires it, but an ambiguous call parks for a person. Model the
money movement as a row (as most serious Rails money apps do) and you get the full
exactly-once guarantee.
