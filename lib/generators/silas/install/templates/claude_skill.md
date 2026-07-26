---
name: silas
description: Build and modify AI agents in this Rails app with the Silas gem — tools, approvals, effect modes, schedules, channels, evals. Use whenever a task touches app/agent/, app/agents/, a Silas tool, an agent's instructions or limits, or agent durability/approval behaviour.
---

# Building Silas agents

Silas runs durable AI agents inside this Rails app: every turn survives
`kill -9` and resumes from its last completed step, tool effects are
exactly-once, and risky calls park for a human at zero compute. The agent is
the `app/agent/` directory — you build agents by writing ordinary Ruby files
there, not by calling a framework API.

**Deep reference lives in the installed gem** — read it from the bundle when
you need more than this file:

```sh
bundle show silas   # then read README.md, docs/*.md, DEPLOY.md there
```

## The directory is the agent

```
app/agent/
  instructions.md   # persona (ERB; snapshotted once per turn)
  agent.yml         # model + limits — data only, no code
  tools/            # one file per tool; TOOL IDENTITY IS THE FILENAME
  skills/           # markdown playbooks, loaded on demand (description: frontmatter)
  schedules/        # cron.md (frontmatter) or .rb handlers -> silas:schedules compiles them
  channels/         # transports (slack.rb, email.rb; generate more, see below)
app/agents/<name>/  # NAMED agents: same tree per agent, own tools/skills/schedules
```

Files register at boot — restart the server after adding one.

## Writing a tool (the part to get right)

```ruby
# app/agent/tools/issue_refund.rb  ->  tool "issue_refund"
class Agent::Tools::IssueRefund < Silas::Tool
  description "Refund part or all of an order."
  param :amount_pence, :integer, desc: "Amount in pence"
  approval ->(session:, input:) { input[:amount_pence] > 2000 ? :user_approval : :approved }
  transactional!

  def call(order_id:, amount_pence:, reason:)
    Refund.create!(order_id:, amount_pence:, reason:)
  end
end
```

- **The keyword signature of `#call` IS the schema** the model sees. Keywords
  only — never positional. `param` refines types/descriptions.
- **Return a Hash** (anything else is wrapped as `{"value" => ...}`). Raising
  records a failed invocation the model sees — don't rescue-and-swallow.
- `session` is available inside `call` (the `Silas::Session` row).

### Effect mode — decide by where the side effect lives

| The tool… | Declare | Why |
|---|---|---|
| writes this app's database | `transactional!` | effect + ledger row commit atomically: **exactly-once**, even through `kill -9` |
| calls an external API / sends anything | `at_most_once!` (the default) | a crash mid-call leaves it IN DOUBT → parks for a human verdict, never re-fires blind |
| only reads, safe to repeat | `idempotent!` | replays re-run it freely |

Never mark an external call `transactional!` — the ledger cannot roll back a
sent email. Model money as rows in this app's own DB whenever possible; that
is what upgrades the guarantee to exactly-once.

### Approval — who holds the lever

`approval :never` (default) · `:always` · `:once` (one approval per identical
(tool, arguments) pair per session) · or a lambda returning `:user_approval`,
`:approved`, `:not_applicable`, or `{denied: "reason"}`. Approval parks the
turn at zero compute; a human settles it in the inbox (`/silas/inbox`), Slack,
email, or the JSON API. Gate anything that moves money or is hard to reverse.

The built-in `ask_question` tool is the reverse direction: the agent parks to
ask the operator something and resumes with their text as the tool result.

## agent.yml

```yaml
model: claude-sonnet-4-5   # must exist in ruby_llm's registry
description: One line, shown in rosters.
limits:
  max_steps: 10     # model calls per turn
  max_cost: 0.25    # dollars per turn
  timeout: 300      # seconds of ACTIVE work — approval waits don't count
final_answer:       # optional JSON schema -> Turn#answer_data
  type: object
  properties: { verdict: { type: string } }
```

Budget breaches PARK the turn (a human can top up in the inbox); they don't
destroy work.

## Rules that protect the durability contract

1. **Solid Queue (or `:inline` for scripts) — never the Async adapter.** Async
   double-executes continuation steps and silently voids exactly-once. Boot
   raises in production if misconfigured.
2. **Don't deploy tool/skill changes while turns are parked.** The definitions
   digest fails a parked turn loudly on resume rather than running it against
   a different agent (`NondeterminismError`). Settle parked turns first —
   the same applies to toggling built-ins like `config.ask_question`.
3. **Keep `Silas::DeadJobRescuerJob` in `config/recurring.yml`** — it is part
   of the crash-recovery contract, and monitor worker liveness: the rescuer
   can requeue work, it cannot conjure a consumer.
4. **Never hand-delete `solid_queue_processes` rows** — a claimed job whose
   process row is gone is invisible to every reaper.
5. Tools must not spawn threads or run work outside `call` — everything the
   ledger can't see is outside the guarantee.

## Verify your work

```sh
bin/rails silas:doctor      # key, queue adapter, model, migrations, tools, rescuer
bin/rails silas:chat        # talk to the agent from the terminal
bin/rails silas:eval        # run test/agent_evals/*_eval.rb (deploy gate)
```

Write an eval per behaviour you care about (`Silas::Eval.scenario` — see the
generated `test/agent_evals/example_eval.rb`). The inbox at `/silas/inbox` is
deny-by-default: wire `config.inbox_auth` in `config/initializers/silas.rb`
before expecting to see it.

## More surface, same pattern

- **Another transport**: `bin/rails g silas:channel whatsapp` scaffolds the
  signature-verifying webhook AND the outbound half (docs/channels.md in the gem).
- **A staff of agents**: `app/agents/<name>/` with its own tree;
  `Silas.agent("name").start(input: ...)`; schedules in that directory tick
  that agent.
- **Subagents / handoffs / memory / connections (MCP)**: see the gem README —
  each is a directory or YAML file, never an orchestration graph.
