# The Silas playground — Tinker & Co

A real, runnable Rails 8.1 app built on [Silas](../..): a small shop whose
support agent looks up orders and issues refunds. Two pages, one database:

- **`/`** — the customer chat. Tokens stream in as the agent answers; every
  tool call renders as it lands; a refund over £20 parks in front of you.
- **`/silas/inbox`** — the operator side of the same rows: live trace, cost,
  the audit trail, and the Approve button that resumes the customer's turn.

## Run it

```sh
bin/setup          # bundle, db:prepare, seeds
bin/dev            # web + worker + css (Procfile.dev)
```

**No API key needed**: without `ANTHROPIC_API_KEY` a scripted stand-in
([lib/demo_engine.rb](lib/demo_engine.rb)) plays the model — the tools, the
ledger, the approval park, and the token streaming are all still real. Export
a key and restart to talk to the actual model.

Then try, at `http://localhost:3000`:

> Hi, I'm ada@example.com — the walnut pen tray was scratched.

£15 — under the gate. The refund applies immediately (`transactional!`: the
Refund row and the ledger row commit together) and the card reads
*auto-approved by policy*.

> I'm ada@example.com and the brass desk lamp arrived cracked.

£48 — over the gate. The turn **parks at zero compute** and an approval card
appears. Approve it (operator password below, or from `/silas/inbox`) and the
turn resumes, executes the refund **exactly once**, and streams the answer
into the customer page.

## The operator password

Reads of `/silas/inbox` are public here (it's a demo — watch the trace from
the other side of the glass). Writes — approve, decline, cancel, budget
top-up — need HTTP basic auth:

```sh
PLAYGROUND_OPERATOR_PASSWORD=letmein bin/dev   # or put it in .env
```

## The party trick

Mid-turn, kill the worker as hard as you like:

```sh
pkill -9 -f bin/jobs
```

Restart `bin/dev`. The rescuer retries the dead job, the turn resumes from its
last completed step, and the store ends up with **exactly one** refund row —
never two, never zero. Refresh the chat page at any point: everything on it
renders from durable rows, so it always shows the truth.

## What to read

```
app/agent/
  instructions.md        # the persona and the refund policy
  agent.yml              # model + per-turn budgets (steps, cost, timeout)
  tools/issue_refund.rb  # the whole thesis: transactional! + a graded gate
test/agent_evals/        # four evals pinning the flow (bin/rails silas:eval)
lib/demo_engine.rb       # the keyless scripted engine
app/views/chats/         # the customer page — renders the ENGINE's own trace
                         # partials; live updates arrive from Silas's own
                         # broadcasts with zero custom streaming code
```

Notes: `config/database.yml` and `config/cable.yml` deliberately run
solid_queue and solid_cable **in development** — the async defaults would void
the durability contract and eat worker-emitted token deltas
(`bin/rails silas:doctor` checks both). Evals run against your development
database by design here (the seeds use fixed ids and reset cleanly); re-run
`bin/rails db:seed` whenever you want the shop pristine.
