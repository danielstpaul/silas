---
title: Home
nav_order: 1
---

# silas — the agent framework for Rails

Durable AI agents as a directory of plain files, inside the app you already
run. Three guarantees the category doesn't ship: **tool effects land exactly
once**, **consequential calls hold at the signal until a person clears them**,
and **turns survive `kill -9`** and resume byte-identical — verified by a
reproducible chaos harness, not asserted.

Honestly early and honestly narrow: 0.5.x, one maintainer, zero external
users, Rails-only on purpose.

<p align="center">
  <img src="https://raw.githubusercontent.com/danielstpaul/silas/main/docs/img/silas-hero-dark.png" width="900"
       alt="app/agents/analyst/ on the left, a durable turn holding at a signal in the middle, the inbox approval card on the right">
</p>

## Sixty seconds, no API key

From nothing:

```bash
rails new desk -m https://raw.githubusercontent.com/danielstpaul/silas/main/template.rb
cd desk && bin/dev
```

Or in the app you already have:

```bash
bundle add silas
bin/rails generate silas:install && bin/rails db:migrate
```

The template builds a working refund desk: paste *"The walnut monitor stand
(order R-1002) arrived cracked."* into the inbox, watch the £64 refund hold at
the signal, clear it, and count exactly one refund row. A scripted stand-in
drives the keyless demo through the real tools, real ledger, and real hold.

## Where to go

- **[The tutorial](tutorial)** — build the desk outward, one primitive per
  chapter: tools, evals, schedules, Slack, questions, memory, staff, budgets,
  deploy.
- **[Why Silas](why-silas)** — the pitch, the honest limits, and who should
  close the tab.
- **[Silas vs eve](vs-eve)** — a date-stamped, engineer-to-engineer
  comparison.
- **[Configuration](configuration)** — every option, with defaults.

Everything here also ships **inside the gem** — `bundle show silas`, then read
`docs/` offline. The installer writes a Claude Code skill so a coding agent
building on your app already knows the rules.
