# Memory

Silas memory is **graph-shaped, not a graph database**: facts stored as
`subject · attribute · content` triples with provenance and supersession —
"author:jane · report_format: prefers CSV", and a new value retires the old
one instead of piling up beside it.

## Approval-gated by default

The first time the model calls `remember`, nothing persists — the memory
**parks as a card in your inbox** and you approve or decline it
(`config.memory_approval = :always`, the default). An agent that can silently
write its own long-term memory is an agent that can silently drift;
the gate keeps a person in that loop. `:never` auto-approves once you trust
an agent's judgment, and `config.memory = false` removes the tools entirely.

## Recall

A handful of the most recent relevant memories (default 8,
`config.memory_injection_limit`) are injected into each turn automatically;
the `recall` tool digs deeper on demand. Memories are private per agent, or
`shared: true` for the whole staff.

## What belongs here — and what doesn't

Memory is for the fuzzy residue with no natural home: preferences, standing
context, things a colleague would jot in a notebook. Your **domain data does
not belong here** — it belongs in your own tables, which your tools already
read. If it has a schema, it's a model; if it's a remark, it's a memory.

## The fine print

Memory tools are model-visible state, so toggling `config.memory` (like any
builtin) changes the definitions digest — settle parked turns before flipping
it, or they fail loudly on resume ([guarantees](guarantees.md)).
