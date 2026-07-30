# Evals

Agent evals answer the question tests can't: *given these model decisions, does
the durable machinery do the right thing?* A scenario scripts the **model's
decisions** step by step; everything else is real — the real registry resolves
your real tools, the real Ledger enforces effect modes and approvals, and the
assertions read the genuine durable transcript, not a mock.

They run keyless and deterministically, which makes them a **deploy gate**:

```sh
bin/rails silas:eval     # loads <eval_dir>/**/*_eval.rb; exits 1 on failure
```

The installer wires this into `bin/ci` (or tells you to add it to yours), and
the application template generates a working example in
`test/agent_evals/refund_desk_eval.rb`.

## A scenario

```ruby
Silas::Eval.scenario "over the gate: a £64 refund holds at the signal" do
  input "The walnut monitor stand (order R-1002) arrived cracked."

  on_step 0, call: { name: "lookup_order", arguments: { number: "R-1002" } }
  on_step 1, call: { name: "issue_refund",
                     arguments: { number: "R-1002", amount_pence: 6400, reason: "arrived cracked" } }

  expect do
    assert_parked tool: "issue_refund"   # the turn holds at zero compute
    assert_no_tool_called "issue_refund" # and the refund row does NOT exist
  end
end
```

`on_step index, ...` is the script: what the "model" returns on that model
call. `text:` is an assistant text block, `call:`/`calls:` are tool calls. A
step index with no entry ends the scripted conversation.

## The DSL

| Call | Meaning |
|---|---|
| `input "…"` | The turn's input. Required. |
| `on_step i, text:, call:, calls:, data:` | The scripted model output for step `i`. `data:` scripts a **structured answer** (the `final_answer` schema case) — it becomes the same block the real adapter persists, so `assert_answer_data` reads it back. |
| `approve tool: "name"` | When the turn parks on this tool, approve it (recorded as approved by `"eval"` — the same `approve!` the inbox uses) and resume. This is how you assert exactly-once **across** a hold. |
| `stub_tool "name", effect_mode:, approval: { \|**args\| … }` | Replace a real tool with a stub for a side-effect-free scenario. Unstubbed tools stay real. |
| `mode :real` | Drive a real model instead of the script. **Skipped automatically when `ANTHROPIC_API_KEY` is unset**, so the gate stays green offline. |
| `max_steps n` | Override the per-turn step cap for this scenario. |
| `metadata h` / tags on `scenario "…", tags: [...]` | Stamped on the session / used for filtering. |
| `expect { … }` | The assertion block. Required. Runs after the turn reaches its resting state. |

## Assertions

All assertions read only the durable rows, and they **collect** failures — one
run reports every miss, not just the first.

| Assertion | Checks |
|---|---|
| `assert_tool_called "name", times: 1` | The tool actually executed (`times:` for exactly-N — the exactly-once assertion). |
| `assert_no_tool_called "name"` | No execution happened (e.g. because the turn parked first). |
| `assert_tool_arg "name", :key, value` (or a block predicate) | An argument the model passed. |
| `assert_parked tool: "name"` | The turn is waiting, held on that tool's approval (or in-doubt). |
| `assert_approved tool: "name"` | The invocation's approval state is `approved`. |
| `assert_turn_completed` / `assert_turn_failed(reason: "…")` | Terminal state. |
| `assert_final_matches(/…/)` | The final answer text. |
| `assert_answer_data(key: :verdict, value: "approve")` | The structured `final_answer` payload (whole-Hash and predicate forms too). |
| `assert_no_hallucinated_price(allowed: [])` | Every money amount in the final answer traces to a number the agent actually saw (tool results or the input), allowing pence↔pounds scaling. |
| `assert_rubric "…" ` | LLM-graded check against `config.eval_grader` — **skips offline** rather than failing the gate (set `SILAS_EVAL_STRICT=1` to make skips fail). |

## How a scenario runs (so you can trust it)

The driver starts a real session (`Silas.agent.start`), runs the real
`AgentLoopJob` inline on the `:test` queue adapter, and — for each `approve
tool:` — performs the same `approve!` an operator would, then resumes the
loop. Scripted mode swaps only the inference adapter; `mode :real` uses your
configured one.

Two consequences worth knowing:

- **Rows persist.** Scenarios commit ordinary durable rows to the database of
  the environment you run them in (they need real seeds for tools that read
  your tables — the template's CI runs `db:seed silas:eval`). Run against a
  scratch database if residue bothers you.
- **Config is restored per run**, but scenarios execute sequentially in one
  process — don't have two scenarios fight over global state you set yourself.

## Configuration

```ruby
Silas.configure do |c|
  c.eval_dir = "test/agent_evals"   # where *_eval.rb files live
  # c.eval_grader = ->(prompt) { … } # custom LLM grader for assert_rubric
end
```

## Replay a real turn against a different model

Evals script the future; replay interrogates the past. Any completed turn can
be re-asked, step by step: *given exactly the history the agent had at this
point, what would a different model (or an edited prompt) have done here?*

```bash
bin/rails silas:replay TURN=31 MODEL=claude-haiku-4-5
```

```
step 0  ✓ same call  find_customer {"query":"ada@example.com"}
step 1  ✓ same call  recent_orders {"customer_id":1}
step 2  ✗ DIVERGED
        recorded  issue_refund {"order_id":1,"amount_pence":4800,…}
        candidate issue_refund {"order_id":1,"amount_pence":2400,…}
        ⚠ approval outcome would change: recorded would_park → candidate auto_approved
```

Three properties make the report trustworthy:

- **Every step is re-conditioned on the recorded rows**, so each comparison
  is like-with-like — the report says *where* the runs part company
  ("agreed through the lookups, split on the refund amount") instead of
  drifting into an unreadable wall of diff.
- **Nothing executes and nothing writes.** Recorded calls are read from the
  ledger; candidate calls are the model's answer to the rebuilt prompt; no
  tool runs, no row is created. The only cost is the candidate's tokens.
- **Approval gates are probed, read-only.** The report tells you when a
  candidate's call would have cleared a gate the original parked on — a
  cheaper model that changes *what gets governed* is a different finding
  from one that words things differently, and it's the one that matters.

`INSTRUCTIONS=path/to/file.md` replays against edited instructions;
`FROM=n` starts partway; no `MODEL` means the null replay — the turn against
its own recorded responses, which must always report zero divergence
(`Silas::Replay` in Ruby, `Silas::Replay.call(turn, model: …)`, returns the
structured result the rake task prints).
