<p align="center">
  <img src="https://raw.githubusercontent.com/danielstpaul/silas/main/docs/img/silas-hero-dark.png" width="1600"
       alt="app/agents/analyst/ on the left, a durable turn holding at a signal in the middle, the inbox approval card on the right">
</p>

<p align="center">
  <a href="https://rubygems.org/gems/silas"><img src="https://img.shields.io/gem/v/silas" alt="Gem"></a>
  <a href="https://github.com/danielstpaul/silas/actions/workflows/ci.yml"><img src="https://github.com/danielstpaul/silas/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/danielstpaul/silas/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

# silas

**The agent framework for Rails.** An agent is a directory of plain files
inside the app you already run — and its guarantees go further than the
category's: tool effects land **exactly once**, consequential calls **hold at
the signal** for a person at zero compute, and turns survive `kill -9` and
resume byte-identical.

```
app/agent/
  instructions.md   # the persona
  agent.yml         # model + limits — data only
  tools/            # one file per tool; filename = identity, keywords = schema
  skills/           # markdown playbooks, loaded on demand
  schedules/        # cron frontmatter -> recurring turns
  channels/         # slack.rb, email.rb — transports bound to the loop
  connections/      # remote MCP servers as <name>.yml
```

**Docs: [danielstpaul.github.io/silas](https://danielstpaul.github.io/silas)** —
start with the [tutorial](https://danielstpaul.github.io/silas/tutorial). The
docs also ship inside the gem (`bundle show silas`).

## Quick start

From nothing — a working refund-desk agent, keyless demo included:

```bash
rails new desk -m https://raw.githubusercontent.com/danielstpaul/silas/main/template.rb
cd desk && bin/dev
```

Or add Silas to an existing app:

```bash
bundle add silas
bin/rails generate silas:install
bin/rails db:migrate
bin/rails silas:doctor
```

## A minimal example

Give the agent a persona in `app/agent/instructions.md`:

```markdown
You are the refund desk. Look orders up before promising anything, and never
quote an amount a tool didn't return.
```

Add a tool at `app/agent/tools/issue_refund.rb` — the keyword signature *is*
the schema the model sees:

```ruby
class Agent::Tools::IssueRefund < Silas::Tool
  description "Refund part or all of an order."
  approval ->(session:, input:) { input[:amount_pence] > 2_500 ? :user_approval : :approved }
  transactional!   # DB effect + ledger commit atomically -> exactly-once

  def call(number:, amount_pence:, reason:)
    order = Order.find_by!(number: number)
    refund = order.refunds.create!(amount_pence:, reason:)
    { refunded_pence: refund.amount_pence, order: order.number }
  end
end
```

Restart, then talk to it — from Ruby, the terminal, the mounted web inbox, or
Slack:

```ruby
session = Silas.agent.start(input: "Refund order R-1002, it arrived cracked")
session.pending_approvals.first.approve!(by: "daniel")   # over £25 -> it held
```

```bash
bin/rails silas:chat
```

Refunds over £25 **hold at the signal** — an amber card in the inbox at
`/silas/inbox` — and approving resumes the turn exactly where it stopped, with
exactly one refund row in your database. That guarantee is measured, not
asserted: a chaos harness `kill -9`s live agents hundreds of times per release
with zero duplicate effects and byte-identical replay
([guarantees](https://danielstpaul.github.io/silas/guarantees)).

## Learn more

| | |
|---|---|
| [Tutorial](https://danielstpaul.github.io/silas/tutorial) | Build the desk outward — one primitive per chapter. |
| [Guarantees](https://danielstpaul.github.io/silas/guarantees) | Exactly-once, in-doubt parking, crash-safe turns, and how they're verified. |
| [Tools & approvals](https://danielstpaul.github.io/silas/tools) | Effect modes, approval policies, skills, `ask_question`. |
| [Agents & staff](https://danielstpaul.github.io/silas/agents) | Named agents, subagents, handoffs, schedules. |
| [Memory](https://danielstpaul.github.io/silas/memory) | Approval-gated triples with provenance. |
| [Inbox & API](https://danielstpaul.github.io/silas/inbox-and-api) | The operator surface, JSON + SSE, streaming, structured answers. |
| [Channels](https://danielstpaul.github.io/silas/channels) | Slack, email, and generating any other transport. |
| [Evals](https://danielstpaul.github.io/silas/evals) | Scripted decisions, real ledger — a deterministic deploy gate. |
| [Budgets](https://danielstpaul.github.io/silas/budgets) · [Cancellation](https://danielstpaul.github.io/silas/cancellation) · [Connections](https://danielstpaul.github.io/silas/connections) · [Sandbox](https://danielstpaul.github.io/silas/sandbox) | Caps and top-ups · cancel semantics · remote MCP tools · code execution. |
| [Configuration](https://danielstpaul.github.io/silas/configuration) · [Deploy](https://danielstpaul.github.io/silas/deploy) | Every option with defaults · Kamal and the worker contract. |
| [Why Silas](https://danielstpaul.github.io/silas/why-silas) · [vs eve](https://danielstpaul.github.io/silas/vs-eve) | Positioning, and an honest comparison. |

The installer also writes a Claude Code skill (`.claude/skills/silas/SKILL.md`),
so a coding agent working in your app already knows these conventions.

## Requirements

Rails >= 8.1 (Active Job Continuations) and Solid Queue >= 1.2. Any model
provider [RubyLLM](https://rubyllm.com) supports.

## Status

Early (0.5.x) and moving fast. The durability contract is chaos-tested on
every release — see [guarantees](https://danielstpaul.github.io/silas/guarantees)
for exactly what's promised today.

## Community

Questions, ideas, and bug reports →
[issues](https://github.com/danielstpaul/silas/issues). For security reports,
please use GitHub's private vulnerability reporting (the repo's Security tab)
rather than a public issue.

## License

[MIT](https://github.com/danielstpaul/silas/blob/main/LICENSE).
