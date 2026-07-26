# Guarantees

Durability in Silas is a contract, not a slide. Everything on this page is
verified by the in-repo chaos harness (`chaos_host/bin/chaos`), which
`kill -9`s live agents hundreds of times per release — the current gate is
100/100 completions per mode across a 295-run matrix, zero duplicate effects,
byte-identical replay, on SQLite and Postgres. Results live in
`chaos_host/results/` and every run is reproducible.

## Turns survive hard process death

Worker `kill -9`, whole-tree `kill -9`, SIGTERM deploys — a turn resumes from
its last completed step. Each step checkpoints through Active Job
Continuations; the resume replays completed work **from rows**, never by
re-calling the model or re-running settled tools.

## `transactional!` tools execute exactly once

The tool's database writes and the ledger's record of "this ran" commit or
roll back **in one transaction**:

- **Crash before commit** → both roll back; resume runs the tool from a clean
  slate. No orphan effect.
- **Crash after commit** → the ledger row says `completed`; resume skips the
  step. No second effect.

No idempotency key is required, because the dedup lives in your database — the
same transaction as the effect. This is the guarantee that requires the ledger
to live *inside* your app: a runtime outside your database can retry and
reconcile, but it can't make its record and your effect one atomic commit.

## Ambiguity parks instead of guessing

The default effect mode is `at_most_once!`: when a crash makes an execution
ambiguous ("did the email send?"), the invocation parks **in doubt** for a
human verdict rather than re-firing blind. `idempotent!` is the explicit
opt-in to automatic re-runs. Never double-pay; sometimes ask.

## Approvals park at zero compute

A turn awaiting a human exits the worker entirely — no held thread, no polling
loop. Approving enqueues a fresh job that replays from rows. Parks expire
(default 7 days, `config.approval_ttl`) rather than ghosting forever.

## Errors can't strand a turn

Transient model errors (rate limits, overloads, timeouts) back off and retry
from the checkpoint. Exhausted retries and permanent rejections (bad key, bad
request) expire pending approvals and fail the turn loudly. And a turn can
never sit in `running` forever: the recurring `DeadJobRescuerJob` retries jobs
failed by dead-worker reaping and fails turns stranded by a loop job that died
outside the retry list. The rescuer is part of the contract — keep it in
`config/recurring.yml`, and monitor worker liveness (the rescuer can requeue
work; it cannot conjure a consumer).

## Deploys can't corrupt a run

Instructions are snapshotted per turn. Tools, skills, connections, and the
final-answer schema are model-visible state, captured in a definitions digest —
a deploy that changes them while a turn is parked fails that turn loudly on
resume (`NondeterminismError`) instead of quietly resuming into a different
agent. Settle parked turns before shipping agent changes.

## Compaction can't corrupt a replay

Long conversations summarise past `config.compact_at` — but a summary is a
**persisted, exactly-once effect** (claimed compare-and-swap, written once),
never a rebuild-time computation. The message array a resumed turn sees is
byte-identical to the one the crashed turn saw.

## The one rule you owe the contract

Run agents on Solid Queue (or `:inline` for scripts) — never ActiveJob's
in-process `:async` adapter, which runs a re-enqueued continuation
concurrently with the original and double-executes steps. Silas raises on it
in production; `bin/rails silas:doctor` flags it everywhere.
