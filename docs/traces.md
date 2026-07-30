# The trace schema

Every step your agent takes is rows in **your** database — transactional,
priced, and joinable to the business rows the agent touched. Most frameworks
treat their execution record as internal bookkeeping in a store beside your
app. Silas treats it as **a documented, versioned interface**: your analytics,
your dashboards, and your own tooling are meant to query these tables
directly.

That is the whole point of the trace living where it does. An external
observability platform can show you what the agent said; it cannot join the
tool call to the `refunds` row it created, in one query, with no export:

```sql
SELECT ti.tool_name, ti.arguments, ti.approved_by, r.amount_pence
FROM silas_tool_invocations ti
JOIN refunds r ON r.id = json_extract(ti.result, '$.refund_id')
WHERE ti.approval_state = 'approved';
```

## The contract

Columns documented here are **stable within a major version**: they may gain
siblings in any release, but renames and semantic changes only happen at a
major, and appear in the CHANGELOG under an upgrade note. Columns *not* listed
here are internal — query them if you like, but they can move without notice.

## `silas_sessions` — a conversation

| Column | Meaning |
|---|---|
| `agent_name` | Which agent owns the session (`"agent"` = the root agent). |
| `status` | `active` \| `archived`. **Note:** parked work is a *turn* state, not a session state. |
| `parent_session_id` | Set when this session was created by a handoff or delegation — the lineage the inbox renders. |
| `channel` | The transport that started it (`"slack"`, `"email"`, …), `NULL` for direct/API. |
| `metadata` | JSON. Channel-specific context (e.g. the inbound email's sender). Plain `json`, not `jsonb` — the schema works identically on SQLite and Postgres. |

## `silas_turns` — one request, run durably

| Column | Meaning |
|---|---|
| `index` | Position within the session; `(session_id, index)` is unique. |
| `status` | `queued` \| `running` \| `waiting` (parked for a human) \| `in_doubt` \| `completed` \| `failed` \| `canceled`. At most one non-final turn per session — enforced by `index_silas_turns_single_active`. |
| `input` | What the user (or channel, or schedule) asked. |
| `instructions_snapshot` | The system prompt as rendered **once** at turn start; immutable after. What the model actually saw, forever. |
| `definitions_digest` | Hash of tool schemas + skill descriptions at turn start — the nondeterminism guard that refuses to resume a turn against a changed agent. |
| `failure_reason` | Why a `failed` turn failed (`max_steps`, `definitions_changed`, `job_failed`, budget reasons, …). |
| `input_tokens` / `output_tokens` / `cost_microcents` | Accumulated across the turn's steps. 1,000,000 microcents = $1. |
| `budget_overrides` | JSON. A human's top-up on a budget-parked turn, beating `agent.yml` limits. |
| `started_at` / `finished_at` | Wall-clock bounds. Note `started_at` resets on resume after a park — `limits.timeout` measures *active* time, not human deliberation. |

## `silas_steps` — one model call

| Column | Meaning |
|---|---|
| `index` | Position within the turn; `(turn_id, index)` is unique — at most one persisted model response per slot. |
| `status` | `started` \| `completed`. |
| `model` / `provider` | What actually served this step. Provider is stamped at execution so historical cost survives registry changes. |
| `response_blocks` | The model's full response — text, tool calls — as JSON. Replay rebuilds the conversation from these rows. |
| `stop_reason` | Why the model stopped (`tool_use`, `end_turn`, …). |
| `terminal` | Write-once after completion; **the** loop-control column. A resumed continuation must re-derive the identical step sequence from it. |
| `input_tokens` / `output_tokens` | This step's usage; cost derives from these plus `(model, provider)` pricing at read time. |

## `silas_tool_invocations` — one tool call, exactly once

The heart of the ledger.

| Column | Meaning |
|---|---|
| `tool_call_id` | The model's id for the call. `(step_id, tool_call_id)` is unique — **this index is the exactly-once key**. |
| `tool_name` / `arguments` | What was called, with what. Arguments are model-authored — render escaped. |
| `status` | `pending` \| `started` \| `completed` \| `failed` \| `in_doubt`. |
| `effect_mode` | `transactional` \| `at_most_once` \| `idempotent` — **snapshotted from the tool class at creation**, so editing a tool mid-park cannot change the semantics of an existing invocation. |
| `result` | The tool's return value (or the question's answer, or `{"denied": reason}`). |
| `approval_state` | `NULL` (no gate) \| `required` \| `approved` \| `declined` \| `expired`. `NULL` on a completed invocation means *policy cleared it*; a value means *a decision was made* — that distinction is load-bearing for audit. |
| `approved_by` | Who decided. `NULL` on an auto-cleared gate, an identity string on a human verdict. |
| `approval_expires_at` / `decline_reason` | The TTL, and the human's stated reason. |

**The free labeled dataset.** `approval_state` + `approved_by` +
`decline_reason` record a human's verdict on a specific agent action, with
full context, in production, at zero annotation cost. If you ever train or
evaluate against your own traffic, this is where the labels already are.

## `silas_compactions` — summaries that survive replay

One row per compacted span: `session_id`, `up_to_turn_index` (unique
together — exactly one summary per span no matter how many replays race),
`status`, `summary`, and what the summarisation itself cost (`tokens_before`,
`input_tokens`, `output_tokens`, `model`). Deterministic by construction: the
message builder reads the row, never recomputes.

## `silas_memories` — what the agent knows across sessions

`agent_name`, `scope` (`agent` private \| `app` shared), `subject`,
`attribute_name`, `content`, `status` (`active` \| `superseded`),
`superseded_by_id`, and provenance (`session_id`, `turn_id`). Approval-gated
on write by default. **Single-tenant per deployment** — see
[guarantees](guarantees.md) for the boundary.

## Queries you already own

Cost per agent per day:

```sql
SELECT s.agent_name, date(t.created_at) AS day, SUM(t.cost_microcents)/1e6 AS dollars
FROM silas_turns t JOIN silas_sessions s ON s.id = t.session_id
GROUP BY 1, 2 ORDER BY 2 DESC;
```

Every action a specific person approved, with what it did:

```sql
SELECT ti.created_at, ti.tool_name, ti.arguments, ti.result
FROM silas_tool_invocations ti
WHERE ti.approved_by = 'dana@example.com' ORDER BY ti.created_at DESC;
```

What parked, and for how long, before a human answered:

```sql
SELECT ti.tool_name, ti.approval_state,
       (julianday(ti.updated_at) - julianday(ti.created_at)) * 24 AS hours_parked
FROM silas_tool_invocations ti
WHERE ti.approval_state IN ('approved','declined','expired');
```

The replay principle behind all of this: `Silas::MessageBuilder` reconstructs
the exact prompt at any step from these rows alone, deterministically. Nothing
in the trace reads the clock or mutable state — which is why a crashed turn
resumes byte-identically, and why the trace you query is the trace that
actually ran.
