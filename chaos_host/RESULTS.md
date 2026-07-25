# Silas acceptance gate — chaos results (2026-07-25, v0.4.0)

The Phase 0 spike bar, run against the gem itself (`bin/chaos`). Evidence in
`results/*.jsonl`. Engine: deterministic in-process ChaosEngine (8 steps × 2
transactional tool calls per turn, MODEL_TURN_MS=120); the production
configuration under test: isolated continuation steps, `wait: 0`, ledger on.

Re-run in full for **0.4.0**, which instrumented the ledger's tool-execution
path and the loop's park/budget branches, and renamed the inference seam —
i.e. it touched the exactly-once machinery itself, so the whole matrix ran
rather than a spot check.

| Mode | Store | Runs | Completed | Byte-identical | Duplicate side effects |
|---|---|---|---|---|---|
| worker kill -9 (reap path) | sqlite | 100 | 100/100 | 100/100 | **0** |
| worker kill -9 (reap path) | pg | 100 | 100/100 | 100/100 | **0** |
| supervisor kill -9 (prune path) | sqlite | 10 | 10/10 | 10/10 | 0 |
| supervisor kill -9 (prune path) | pg | 10 | 10/10 | 10/10 | 0 |
| SIGTERM (Kamal deploy shape) | sqlite | 10 | 10/10 | 10/10 | 0 |
| parked approval + hard kill + 24h rewind + approve! | sqlite | 5 | 5/5 | 5/5 | 0 |

**Gate: PASSED** — same bar as spike/SPIKE_RESULTS.md (which additionally
covered real-API chaos timing, 10/10; the gem's real-API path is covered by
`spec/smoke`). Streaming deltas are never persisted, so byte-identical replay
is unaffected by the 0.2 streaming pipeline — these runs confirm it.

Operational notes:
- Every hard-kill run needed exactly one DeadJobRescuerJob rescue; SIGTERM
  needed zero (graceful interrupt re-enqueues itself) — the rescuer is on the
  critical path for SIGKILL only, as designed.
- Recovery ≈ `process_alive_threshold` (2s here) + rescuer cadence.
- Harness runs on a shared desktop: an earlier batch degraded and aborted under
  load-average ~8.5 (timeouts, not correctness — zero dups/mismatches in every
  completed run). Timeouts are now load-tolerant (240s completion, 60s boot).

Reproduce: `bin/rails db:prepare silas:install:migrations db:migrate`, then
`bin/chaos --runs=100 --mode=worker` (and `STORE=pg`, `--mode=supervisor|sigterm|parked`).
