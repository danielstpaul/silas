# Silas acceptance gate — chaos results (2026-07-26, pre-0.5.0)

The Phase 0 spike bar, run against the gem itself (`bin/chaos`). Evidence in
`results/*.jsonl`. Engine: deterministic in-process ChaosEngine (8 steps × 2
transactional tool calls per turn, MODEL_TURN_MS=120); the production
configuration under test: isolated continuation steps, `wait: 0`, ledger on.

Re-run in full for **0.5.0**, which rebound the `:ruby_llm` adapter
(Provider#complete) and added replay-safe context compaction — the latter
touches MessageBuilder and the step path, i.e. the exactly-once machinery's
inputs, so the whole matrix ran plus a new dedicated mode.

## The compact mode (new)

Two-turn sessions: turn 0 completes clean, then turn 1 must compact it
(summary model call + CAS claim) before its first step. The kill window covers
turn 1 **including mid-summarisation**. Three assertions beyond the standard
gate: exactly one completed compaction row however the kill landed, zero
duplicate side effects, and the post-crash `MessageBuilder` rebuild
byte-identical to the control run's.

| Mode | Store | Runs | Completed | Byte-identical | Duplicate side effects |
|---|---|---|---|---|---|
| worker kill -9 (reap path) | sqlite | 100 | 100/100 | 100/100 | **0** |
| worker kill -9 (reap path) | pg | 100 | 100/100 | 100/100 | **0** |
| supervisor kill -9 (prune path) | sqlite | 10 | 10/10 | 10/10 | 0 |
| SIGTERM (Kamal deploy shape) | sqlite | 10 | 10/10 | 10/10 | 0 |
| parked approval + hard kill + 24h rewind + approve! | sqlite | 5 | 5/5 | 5/5 | 0 |
| **compact** (kill mid-turn-1, incl. mid-summary) | pg | 25 | 25/25 | 25/25 + 25/25 messages + 25/25 exactly-once | **0** |
| **compact** | sqlite | 25 | 25/25 | 25/25 + 25/25 messages + 25/25 exactly-once | **0** |

**Gate: PASSED — 275 runs, zero duplicate side effects, zero transcript
divergence.** The compact rows additionally prove the compaction claim is
exactly-once under kill -9 (including kills landing mid-summarisation) and
that the post-crash MessageBuilder rebuild is byte-identical to the control
run's.

Operational notes:
- Every hard-kill run needed exactly one DeadJobRescuerJob rescue; SIGTERM
  needed zero — the rescuer is on the critical path for SIGKILL only, as
  designed.
- **Harness fix this cycle:** `stop_worker`'s pgroup TERM has a refork race — a
  Solid Queue fork spawned inside the supervisor's shutdown window survives as
  an ORPHAN polling the shared dev database, where it silently claims later
  runs' jobs and strands them (its `solid_queue_processes` rows get wiped by
  the next run's reset, so nothing can tell the claim is dead). The harness
  now group-KILLs after TERM and sweeps a persisted pgid registry at every
  reset. The production lesson generalises: never hand-delete
  `solid_queue_processes` rows — a claim without a process row is invisible to
  every reaper.
- Side-effect keys are turn-scoped (`u<turn>_t<step>_c<call>`) — compact mode
  runs multi-turn sessions, and per-turn keys collide across turns and read as
  duplicates that never happened.
- **Second harness finding:** Solid Queue's fork supervisor occasionally fails
  to refork a SIGKILLed worker (3/25 kills in one loaded sqlite batch; 0/348
  elsewhere) — the retried job then sits READY with zero consumers, which
  reads as a strand though every ledger/compaction guarantee is intact.
  `recover` now runs a 5s worker-liveness watchdog that bounces the tree.
  Production translation, for DEPLOY.md: Silas's rescuer can requeue work, it
  cannot conjure a consumer — monitor worker liveness.
- Harness runs on a shared desktop: timeouts are load-tolerant (240s
  completion, 60s boot).

Reproduce: `bin/rails db:prepare silas:install:migrations db:migrate`, then
`bin/chaos --runs=100 --mode=worker` (and `STORE=pg`,
`--mode=supervisor|sigterm|parked|compact`), or the whole matrix via
`bin/full_gate`.
