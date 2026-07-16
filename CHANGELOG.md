# Changelog

## 0.1.1

- **Fix: parallel tool calls.** When the model emitted several tool_use blocks
  in one turn, replay could send a tool_result with no matching tool_use (the
  provider rejects it) and, under a non-serializing queue adapter, double-execute
  the step. The replayed assistant message's tool_use blocks are now
  reconstructed from the settled ledger invocations — every tool_result has a
  matching tool_use by construction — and consecutive tool results are batched
  into a single provider message. Regression test:
  `spec/silas/parallel_tool_calls_spec.rb`.
- **Boot guard: unsafe queue adapter.** Silas now warns at boot if ActiveJob is
  using the in-process Async adapter, which runs continuation retries
  concurrently and breaks exactly-once. Use Solid Queue (production) or `:inline`
  (scripts/demos). See DEPLOY.md.

## 0.1.0

First release. A durable AI agent framework for Rails ("eve without the bill").

- **Durable loop** on Active Job Continuations + Solid Queue — a turn survives
  crash / deploy / `kill -9` and resumes from the last completed step.
  Chaos-gated: 100/100 runs, zero duplicate side effects, byte-identical
  transcripts, on SQLite and Postgres.
- **Exactly-once tool execution** via a transactional ledger (at-most-once with
  in-doubt→human resolution for external effects).
- **Human-in-the-loop approvals** that park at zero compute, resumable from
  Slack buttons, signed email links, or the inbox.
- **`app/agent/` directory convention**: tools (signature = schema), skills
  (progressive disclosure), instructions, schedules (cron → Solid Queue),
  channels (Action Mailbox + Slack), subagents (isolated delegation),
  connections (external MCP servers as tools).
- **Two engines**: `:ruby_llm` (any provider) and `:agent_sdk` (a `claude -p`
  subprocess; API-key auth).
- **Mountable inbox** at `/silas/inbox`: live trace over Turbo Streams, approval
  cards, per-session/agent cost. Deny-by-default.
- **Evals as a deploy gate**: transcript assertions + opt-in LLM rubric, `bin/ci`.
- **Budgets**: cost / token / time caps per turn.
- **Sandbox seam** with a Docker adapter (interim) for untrusted/model code.
- Deploys self-hosted with Kamal to one cheap VPS (see DEPLOY.md).
