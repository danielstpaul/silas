# Agents & staff

## The root agent

`app/agent/` is the default agent: `instructions.md` (the persona — ERB,
snapshotted once per turn), `agent.yml` (data-only config), and directories
for tools, skills, schedules, channels, and connections. Start it from
anywhere in your app:

```ruby
session = Silas.agent.start(input: "Refund order 42, £12.50")
session.continue(input: "Now email the customer.")
```

`agent.yml` keys:

```yaml
model: claude-sonnet-4-5   # must resolve in ruby_llm's registry; defaults to config.default_model
description: One line, shown in rosters.
limits:                    # per-turn caps — see docs/budgets.md
  max_steps: 10
  max_cost: 0.25
  timeout: 300
final_answer:              # optional JSON schema -> Turn#answer_data (structured answers)
  type: object
  properties: { verdict: { type: string } }
  required: [verdict]
```

## Named agents — the staff pattern

One app can employ several agents, each with its own room:

```
app/agents/
  escalations/
    instructions.md
    agent.yml        # same keys as the root agent
    tools/           # its own toolset — the root agent's tools are not inherited
    skills/
    schedules/       # its own cron, ticking IT — not the root agent
```

Sessions are stamped with the agent's name, and every turn — including crash
resumes — runs under that agent's own tools, skills, instructions, and
definitions digest. Scope switching is execution-isolated, so concurrent jobs
running different agents never cross wires.

```ruby
Silas.agent("escalations").start(input: "…")
```

```sh
bin/rails silas:chat AGENT=escalations   # talk to one staff member
```

The inbox filters by agent; the root `app/agent/` stays the default.

## Subagents — delegation within a turn

The built-in `delegate` tool runs a scoped sub-task under a subagent's own
instructions and toolset and returns its answer into the parent turn. Use it
to keep a specialist's tools out of the main agent's prompt until needed.

## Handoffs — durable work between staff

Staff compose through **handoffs, not conversations**: the built-in `handoff`
tool files a self-contained brief that starts a **linked session** for another
named agent — asynchronously by default, or `await: true` for an answer.
Handoffs are cycle-checked, and at-most-once: filing one is a single external
effect, so a crash mid-handoff parks the call **in doubt** for a person rather
than starting the colleague twice. Two models chatting freely is a cost and
audit hazard, so it's deliberately unblessed; a handoff is a work order, with
the paper trail that implies.

## Schedules give any agent a clock

A markdown file in the agent's `schedules/` directory — cron frontmatter, body
= the turn input — compiled by `bin/rails silas:schedules` into Solid Queue
recurring tasks (cron that fires real work stays a reviewable git diff). A
scheduled tick is a normal durable turn for **that** agent: it can hold for
approval, spend budget, and appear in the inbox like any other. `.rb` handlers
(subclassing `Silas::Schedule::Handler`) cover the programmatic cases.
