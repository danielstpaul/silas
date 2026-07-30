# A1 — counterfactual replay: pre-registered evaluation

```
status:       pre-registered — NO replay code exists at time of writing
written:      2026-07-29, against Silas 0.6.3 (branch)
rule:         if this file is edited after results exist, THAT IS THE FINDING.
              Corrections go in a dated addendum below the line, never inline.
```

## The claim under test

`Silas::MessageBuilder.call(turn, upto_index: i)` deterministically
reconstructs the exact prompt at any step — built for crash-safe resume. The
bet: the same primitive, pointed at a *changed* configuration (different
model, edited instructions, added tool), run inside a transaction that **rolls
back**, is a debugging instrument nobody else can build — "what would Haiku
have done at step 7, and would the refund still have been correct?"

This file decides, before the code exists, how we'll know whether that bet is
right. Failure here is cheap; the same discovery at the optimizer stage (A4)
would cost a quarter.

## Two checks before the implementation

**Day 0 — write the demo transcript first.** One page: exact commands, exact
output, faked. If the transcript doesn't make its own author want to run it,
the feature does not exist and no implementation will rescue it. The
transcript becomes the spec — build toward it, not toward an API.

**Day 1 — the null test.** Replay a real turn with *nothing* changed. It must
reproduce the original byte-identically. The chaos harness already asserts
byte-identical replay on resume, so this is nearly free — and if it fails,
counterfactual replay is not unmagical, it is *unsound*, and A1 stops here.

## The known failure mode, designed for up front

Once the model changes at step *n*, step *n+1*'s input differs and the
trajectories diverge — a naive diff silently compares two increasingly
unrelated runs, which is worse than no diff. **Divergence is a first-class
output**: the replay must report where the runs parted and how far they had
drifted by the end. "Agreed through step 9, split at the refund amount" is a
finding. A wall of diff is not.

## Pre-registered thresholds

Run the built engine against **ten real turns already known to have gone
wrong**. Thresholds fixed now:

| Dimension | Test | Kill below |
|---|---|---|
| Friction | Replay a production turn against a different model | One command + one flag |
| Latency | 10-step turn, 3 variants, wall clock | 60 seconds |
| Non-obviousness | Of 10 known-bad turns, how many surfaced a cause NOT already visible in the inbox transcript? | 3/10 |
| Decision change | Of those, how many changed what actually shipped (prompt edit, model swap, tool fix)? | 2 |
| Unprompted reuse | Two weeks later: invocations made during real work, not while testing the feature | 5 |

**Guard on non-obviousness** (the one most temptable to fudge): write down the
suspected cause *before* running the replay, then compare. Hindsight makes
everything look predicted.

## Outside eyes

Show the demo to five Rails engineers who have shipped an LLM feature. The
signal is not "that's cool" — people are polite. **The tell is an immediate,
specific question about their own system** ("could I replay the turn where our
agent double-charged?"). Three or more out of five is a real result.

## Interpreting a flat result

- *"I'd use this if it also did X"* → **packaging.** Thesis holds; fix
  ergonomics.
- *"Interesting, but I'd just read the logs"* → **substance.** The transcript
  already served their debugging; replay solves a problem they don't have.
  Honest response: Silas stands as a durability framework, and Act II
  (traces → datasets → optimization) is dropped, not rationalised.

## Known dependency, stated honestly

The test requires **ten real known-bad turns**, which requires real usage.
Sources, in order of realism: the maintainer's own dogfood apps
(`examples/playground`, the shop back-office), then any early adopter's
traffic offered voluntarily. If no such turns exist when the engine is ready,
the test *waits* — running it against synthetic failures would satisfy the
letter and void the point.

## Out of scope for this test

This judges replay as a *debugging instrument*. A4 (optimization) needs it as
a *rollout mechanism* — batch throughput and cost-per-rollout dominate there,
and none of the five thresholds above apply. **A pass here is not a green
light for the optimizer.**

---

*Addenda (dated, append-only):*
