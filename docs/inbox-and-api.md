# Inbox & API

Everything an operator needs ships in the gem — mount the engine (the
installer does this) and it's there. No dashboard to build, no second console
to deploy.

## The inbox — `/silas/inbox`

A session rail grouped **Held / Working / Filed**, web chat (start a session
or reply from the browser — same durable loop), a live step-trace that
streams tokens over Turbo as the agent runs, approval and question cards
hoisted to the top of the session, a full audit trail (every tool call's
arguments and result, who cleared what and why), cancel, raise-budget, and
per-session token/cost accounting priced from RubyLLM's model registry.

It's **deny-by-default** — invisible until you wire auth:

```ruby
Silas.configure do |c|
  # The lambda DENIES by rendering (or head-ing) and PASSES by not rendering.
  c.inbox_auth = ->(controller) { controller.head :not_found unless controller.current_user&.admin? }
  # c.inbox_public_read = true   # read-only demo mode; writes stay gated
  # c.model_prices["your-fine-tune"] = { in: 3000, out: 15_000 }  # price overrides
end
```

`config.inbox_actor` names the identity recorded on approvals (defaults to
`current_user&.email || "inbox"`). Live streaming activates automatically when
the host app has `turbo-rails` (every default Rails app does); without it the
trace falls back to a polling refresh. The gem takes no turbo dependency.

## The JSON API — `/silas/api/v1`

The same surface over HTTP, also deny-by-default (`config.api_auth`, same
contract as the inbox; `config.api_actor` names the API identity):

```sh
curl -X POST .../silas/api/v1/sessions -d "input=Refund order 42, £12.50"
curl .../silas/api/v1/sessions/1?trace=1                # turns + steps + tool calls
curl .../silas/api/v1/sessions/1/approvals              # what's held
curl -X POST .../silas/api/v1/approvals/7/approve       # the same approve! as the inbox
curl -X POST .../silas/api/v1/approvals/9/answer -d "answer=Use the June invoice"
curl -X POST .../silas/api/v1/sessions/1/turns -d "input=Now email them"   # 409 if busy
curl -X POST .../silas/api/v1/turns/9/cancel
curl -N .../silas/api/v1/sessions/1/stream              # server-sent events
```

The stream is SSE at **row granularity** — turn, completed-step, and
invocation changes, at-least-once with `Last-Event-ID` resume (ids are
epoch-ms watermarks). `?poll=1` returns the backlog and closes, curl-friendly;
streams close themselves after `config.api_stream_max_duration` and clients
reconnect. Per-token streaming is deliberately the browser/Turbo feature:
deltas live in the worker process, and the gem requires no cross-process bus.

## Streaming — decoration over durable rows

Turns stream everywhere it helps: `silas:chat` prints tokens as they arrive,
and the inbox renders them live (coalesced to ~10Hz). Deltas are never
persisted, never fed back to the model, and absent from replays — a replayed
step renders from its row — so streaming adds zero risk to the durability
contract. Custom sinks subscribe to the `"delta.silas"` notification
(`{ session_id:, turn_id:, step_id:, step_index:, text: }`, where `text` is
the accumulated string so far; filter by ids — notifications are
process-global).

## Structured answers

Give the turn's final answer a schema in `agent.yml`:

```yaml
final_answer:
  type: object
  properties:
    verdict: { type: string }
    amount_pence: { type: integer }
  required: [verdict]
```

`Turn#answer_data` returns the parsed Hash (`answer_text` stays for prose
agents); the API carries it as `answer_data`, and evals assert on it with
`assert_answer_data(key: :verdict, value: "approve")`. Rendered through
RubyLLM's `with_schema`, so each provider's native structured-output mode is
used. The schema is model-visible state — changing it mid-turn fails the turn
loudly rather than resuming into a different contract.
