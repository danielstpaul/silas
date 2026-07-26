<!-- Thanks! Two notes before you start:
     - Anything that adds surface area should have an issue agreed first —
       see CONTRIBUTING.md, including the list of things Silas deliberately
       doesn't do.
     - Small fixes (typos, docs, a failing-test repro) are welcome cold. -->

## What & why



## Checks

- [ ] `bundle exec rspec` (SQLite) and `STORE=pg bundle exec rspec` pass
- [ ] `bundle exec rubocop` clean
- [ ] Touched the loop, ledger, step runner, or message builder → chaos gate
      run (`chaos_host/bin/chaos --runs=100 --mode=worker`, both stores) and
      results noted below
- [ ] Touched a generator or template → `templates_smoke` run locally
      (`SILAS_PATH=$PWD rails new smoke -m templates/desk.rb --skip-git`)
- [ ] Docs updated where behavior changed (`docs/`, `CHANGELOG.md`)

## Durability notes

<!-- Only if the change touches the loop/ledger/replay path: what does this
     do to exactly-once effects and byte-identical replay? Chaos results? -->
