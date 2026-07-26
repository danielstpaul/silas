# Budgets

A turn gets four caps. Breaching `max_input_tokens`, `max_cost`, or `timeout`
**parks the turn** — like an approval, at zero compute — completed work is
never destroyed, and a human can top the cap up and resume from the inbox.
`max_steps` is different: it's the runaway-loop guard, and hitting it **fails
the turn loudly** (`failure_reason: "max_steps"`).

## The caps

Declared per agent in `agent.yml` (each is optional; unset = uncapped, except
`max_steps` which defaults from `config.max_steps`):

```yaml
limits:
  max_steps: 10           # model calls per turn
  max_input_tokens: 200000 # cumulative input tokens across the turn's steps
  max_cost: 0.25          # dollars per turn (priced tokens only)
  timeout: 300            # seconds of ACTIVE work — held time doesn't count
```

## Semantics — the details that matter

- **Checks run between steps**, in the framework-owned loop, never inside a
  continuation step. A cap can't fire mid-model-call; the in-flight step's
  work always commits.
- **Token and cost checks are deterministic** — they read the persisted step
  rows, so a crash-replay reaches the same verdict.
- **Cost only counts priced tokens.** Pricing comes from RubyLLM's model
  registry, overridable per model with `config.model_prices` (fine-tunes,
  custom deployments, models newer than your installed registry). A model the
  registry can't price can't be cost-capped.
- **`timeout` measures active wall-clock.** The clock **restarts when an
  approval resumes the turn** — it bounds active stretches of work, never the
  hours a human spends deciding. Crash-rescue resumes keep the original clock:
  the turn was live the whole time. (Reading the clock is benign
  non-determinism: a cap firing later on a replay is still a correct cap — the
  turn genuinely ran too long across the crash.)

## What a breach looks like

The turn parks with status `waiting` and the breached cap as its park reason
(`max_input_tokens` / `max_cost` / `timeout`). In the inbox the turn shows
**held** with a raise-budget control; over the API it's visible on the
session's turns.

## Topping up

`Turn#raise_budget!` records a **per-turn override** that beats the agent's
configured limit for that cap, then resumes the turn:

```ruby
turn.raise_budget!(max_cost: 1.00)
```

The inbox's raise-budget button does exactly this. Overrides live on the turn
(`budget_overrides`), so one generous exception never loosens the agent's
standing limits.

## Choosing limits

Set `max_cost` on anything using an expensive model — it's the cap that maps
to money. `max_steps` is the runaway-loop guard. `timeout` protects worker
slots from a wedged provider (the adapter's own request timeout should be
tighter). `max_input_tokens` is mostly superseded by compaction
(`config.compact_at` summarises long conversations instead of failing them) —
keep it as a hard ceiling if you cap spend per turn strictly.
