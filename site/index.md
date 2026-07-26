---
title: Home
nav_order: 1
---

# silas

Silas is a Rails-native framework for durable AI agents. An agent's
capabilities live as plain files in conventional locations inside the app you
already run — easy to inspect, extend, and operate — and its tool effects
land **exactly once**, even through a crash.

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

## Quick start

```bash
rails new my-agent -m https://raw.githubusercontent.com/danielstpaul/silas/main/templates/desk.rb
cd my-agent && bin/dev
```

This creates a new agent app with Solid Queue wired, a starter refund-desk
agent installed, and a keyless demo — no API key needed for the first run.
To add Silas to an existing app instead:

```bash
bundle add silas
bin/rails generate silas:install && bin/rails db:migrate
```

## Learn

Start with the **[tutorial](tutorial)** — it builds the refund desk outward,
one primitive per chapter — and read **[guarantees](guarantees)** for what's
promised (exactly-once effects, holds at zero compute, crash-safe turns) and
how each claim is verified. Everything else is in the sidebar: **Core** for
the pieces every agent uses, **Advanced** for the rest, **Reference** for
configuration and deploy.

All of these docs also ship inside the gem — `bundle show silas`, then read
`docs/` offline — and the installer writes a Claude Code skill so a coding
agent building on your app already knows the conventions.
