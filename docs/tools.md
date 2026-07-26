# Tools & approvals

A tool is one file in `app/agent/tools/`. The filename is the tool's identity;
the keyword signature of `#call` is the schema the model sees. No registry, no
wiring — add a file, restart, and the model can use it.

```ruby
# app/agent/tools/issue_refund.rb  ->  the "issue_refund" tool
class Agent::Tools::IssueRefund < Silas::Tool
  description "Refund part or all of an order."
  param :amount_pence, :integer, desc: "Amount in pence (1800 = £18.00)"
  approval ->(session:, input:) { input[:amount_pence] > 2_500 ? :user_approval : :approved }
  transactional!

  def call(number:, amount_pence:, reason:)
    order = Order.find_by!(number: number)
    refund = order.refunds.create!(amount_pence:, reason:)
    { refunded_pence: refund.amount_pence, order: order.number }
  end
end
```

The rules:

- **Keywords only** — the keyword signature *is* the schema; `param` refines
  types and descriptions.
- **Return a Hash** (anything else is wrapped as `{"value" => ...}`). Raising
  records a failed invocation the model sees — don't rescue-and-swallow.
- `session` is available inside `call` (the `Silas::Session` row), so tools
  can read channel metadata or scope queries.

## Effect modes — decide by where the side effect lives

| The tool… | Declare | What you get |
|---|---|---|
| writes this app's database | `transactional!` | effect + ledger commit atomically → **exactly-once**, even through `kill -9` |
| calls anything external (email, HTTP, Slack…) | `at_most_once!` (the default) | a crash mid-call leaves it **in doubt** → parks for a human verdict, never re-fires blind |
| only reads, safe to repeat | `idempotent!` | crash replays may re-run it freely |

Never mark an external call `transactional!` — the ledger cannot roll back a
sent email. Model money as rows in your own database wherever you can; that's
what upgrades the guarantee to exactly-once
([guarantees](guarantees.md)).

## Approval — who holds the lever

```ruby
approval :never    # default — runs without asking
approval :always   # every call parks for a human
approval :once     # one approval per identical (tool, arguments) pair per session
approval ->(session:, input:) { ... }  # decide from the arguments
```

A lambda returns `:user_approval`, `:approved`, `:not_applicable`, or
`{denied: "reason"}` (the denial rides back to the model as the tool result).
Parking costs nothing — the turn **holds at the signal** at zero compute until
someone clears it from the inbox, Slack, a signed email link, or the JSON API,
all calling the same `approve!`/`decline!`. Parks expire after
`config.approval_ttl` (default 7 days).

The built-in **`ask_question`** tool is the reverse direction: the agent parks
to ask the operator something — information, not permission — and their typed
answer resumes the turn as the tool result.

## Skills — playbooks, loaded on demand

A skill is a markdown file in `app/agent/skills/` with a `description:`
frontmatter line. The description is always visible to the model as a routing
hint; the body loads only when the model asks for it (`load_skill`), keeping
the always-on prompt small. Put procedures in skills; put identity in
`instructions.md`.

## Remote tools

`app/agent/connections/*.yml` plugs a remote MCP server's tools in under the
same ledger, namespaced `<connection>__<tool>` — see
[connections](connections.md).
