# Contributing to Silas

Thanks for looking. Silas is early and moving fast, so the most valuable
contributions right now are **real-world reports**: what you built, where the
framework fought you, and anything that violated the durability contract.

## Ground rules

- **Open an issue before a big PR.** Small fixes (typos, docs, a failing-test
  repro) are welcome cold; anything that adds surface area should be agreed
  first — the scope list below explains why.
- **The durability contract is load-bearing.** Changes touching the loop, the
  ledger, the step runner, or the message builder must pass the chaos gate
  (`chaos_host/bin/chaos`, worker mode ×100 minimum, both stores) as well as
  the spec suite. A PR that weakens exactly-once or byte-identical replay will
  be declined regardless of what it gains.
- **Replays must stay deterministic.** Nothing under `Silas::MessageBuilder`
  may read the clock or mutable state; anything a model can see is part of the
  definitions digest. If your change makes a parked turn resume differently,
  it needs a very good reason and a loud failure mode.

## Running the project

```sh
bin/setup
bundle exec rspec              # SQLite
STORE=pg bundle exec rspec     # Postgres
bundle exec rubocop
cd chaos_host && bin/chaos --runs=100 --mode=worker   # for loop/ledger changes
```

The generated-app path has its own gate: `templates/*.rb` are regenerated and
tested by the `templates_smoke` workflow on every push — if you change a
generator or a template, run it locally first
(`SILAS_PATH=$PWD rails new smoke -m templates/desk.rb --skip-git`).

## Scope — what Silas deliberately does not do

These are decisions, not gaps. PRs adding them will be declined with a link
here:

| Not doing | Because |
|---|---|
| Provider abstraction, model routing, token counting | [RubyLLM](https://rubyllm.com)'s job. One inference seam, no wrapping. |
| Hosted state / a managed Silas cloud | The whole point is that agent state lives in **your** database, inside your transaction boundary. |
| RAG, vector stores, embeddings | Retrieval is its own category with good Ruby options; compose them as tools. |
| More first-party channels | Each is a vendor API drifting forever. `rails g silas:channel` is the answer. |
| React/Vue/Svelte component libraries | Rails' answer is the mounted engine + Turbo. |
| Separate template repos | Templates live in `templates/` here as single CI-gated `rails new -m` scripts that execute the tested generators — they structurally can't rot. New templates are welcome **as proposals first**. |

## Releases

Maintainer-driven: squash-merge, then a GitHub release triggers Trusted
Publishing to RubyGems. Every release runs the full suite, RuboCop, Brakeman,
and the chaos gate where the loop changed.
