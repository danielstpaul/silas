<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/danielstpaul/silas/main/brand/silas-mark.svg">
    <img src="https://raw.githubusercontent.com/danielstpaul/silas/main/brand/silas-mark-light.svg" alt="Silas" width="72" height="72">
  </picture>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/silas"><img src="https://img.shields.io/gem/v/silas" alt="Gem"></a>
  <a href="https://github.com/danielstpaul/silas/actions/workflows/ci.yml"><img src="https://github.com/danielstpaul/silas/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/danielstpaul/silas/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

# silas

Silas is a Rails-native framework for durable AI agents. An agent's
capabilities live as plain files in conventional locations inside the app you
already run — easy to inspect, extend, and operate — and its tool effects
land **exactly once**, even through a crash.

## The filesystem is the authoring interface

A typical Silas agent:

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

Documentation lives at
**[danielstpaul.github.io/silas](https://danielstpaul.github.io/silas)** —
start with the [tutorial](https://danielstpaul.github.io/silas/tutorial). The
same docs ship inside the gem (`bundle show silas`), and the installer writes
a Claude Code skill so coding agents working in your app know the conventions.

## Quick start

```bash
rails new my-agent -m https://raw.githubusercontent.com/danielstpaul/silas/main/template.rb
```

This creates a new agent app with Solid Queue wired, a starter refund-desk
agent installed, and a keyless demo — the first `cd my-agent && bin/dev`
needs no API key.

To add Silas to an existing app:

```bash
bundle add silas
bin/rails generate silas:install
bin/rails db:migrate
```

`bin/rails silas:doctor` verifies the whole setup.

## A minimal example

Replace `app/agent/instructions.md` with your agent's persona:

```markdown
You are the refund desk. Look orders up before promising anything, and never
quote an amount a tool didn't return.
```

Create a tool at `app/agent/tools/issue_refund.rb` — the keyword signature
*is* the schema the model sees:

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

Restart, then talk to it:

```bash
bin/rails silas:chat
```

Refunds over £25 hold for a person — in the operator inbox the gem mounts at
`/silas/inbox`, in Slack, or over the JSON API — and approving resumes the
turn exactly where it stopped, with exactly one refund row in your database.
How that's guaranteed (and verified with a `kill -9` chaos harness on every
release): [guarantees](https://danielstpaul.github.io/silas/guarantees).

## Status

Early (0.5.x) and moving fast. Requires Rails >= 8.1 (Active Job
Continuations) and Solid Queue >= 1.2; any model provider
[RubyLLM](https://rubyllm.com) supports.

## Community

Questions, ideas, and bug reports →
[issues](https://github.com/danielstpaul/silas/issues). For security reports,
please use GitHub's private vulnerability reporting (the repo's Security tab)
rather than a public issue.

## License

[MIT](https://github.com/danielstpaul/silas/blob/main/LICENSE).
