# Connections

A connection plugs a remote MCP server's tools into your agent the same way
everything else plugs in: **one data-only file, identity = filename.**

```yaml
# app/agent/connections/crm.yml
url: https://mcp.example-crm.com/mcp
auth:
  type: bearer                     # or `header` with a `header:` name, or omit
  credential: crm.mcp_token        # a PATH into Rails credentials — never the secret
approval: once                     # never (default) | once | always
effect: at_most_once               # at_most_once (default) | idempotent
```

Restart, and the server's tools appear to the model namespaced
`crm__search`, `crm__create_note`, … — alongside your local tools, running
through the same Ledger.

## The rules the file encodes

- **Credentials are paths, not secrets.** `credential: crm.mcp_token` resolves
  `Rails.application.credentials.dig(:crm, :mcp_token)` at call time. The YAML
  is committable; a missing credential fails loudly with the path named.
- **Approval and effect mode are per-connection**, enforced by the same Ledger
  as local tools. `approval: always` parks every remote call for a human;
  `once` approves an identical (tool, arguments) pair once per session.
- **`transactional!` does not exist here, by design.** A remote call can't
  join your database transaction, so the honest ceiling is `at_most_once`
  (an ambiguous crash parks in-doubt for a person) or `idempotent` (you're
  asserting the remote op is safe to repeat).
- **Credentials require https.** A connection with `auth:` configured and a
  plaintext `http://` URL fails loudly at parse time (localhost is exempt for
  local development servers).
- **Transport is HTTP** (v1). Filename is the namespace: `crm.yml` →
  `crm__*`.

## Boot-time discovery, fail-loud

Each connection's tool list is fetched **once at boot** and cached
(`tools/list`). A misconfigured or unreachable connection raises **at boot**,
never inside a turn — the same posture as the Registry's tool validation. The
remote tool names and schemas are model-visible state, so they're part of the
definitions digest. A parked turn resumes against its own definitions
snapshot, so a changed remote toolset doesn't fail it — but if the model then
calls a remote tool the server no longer serves, that call fails loudly. A
connection whose toolset moves under parked work is worth settling promptly.

## Testing

`config.mcp_client_factory = ->(connection) { fake_client }` injects a fake
client per connection — the seam the gem's own specs use.

## The other direction — your tools as an MCP server

Mounting the engine also mounts an MCP endpoint at **`POST /silas/mcp`**
(Streamable HTTP, stateless mode — plain JSON request/response). Any MCP
client — goose, Claude Code, an eve agent, Claude Managed Agents over remote
MCP — can call your agent's tools, and every call runs **through the
Ledger**: the same exactly-once semantics, the same effect modes, and the
same approval gates as the in-process loop.

Auth is deny-by-default, same lambda contract as the JSON API:

```ruby
config.mcp_auth = lambda do |controller|
  supplied = controller.request.headers["Authorization"].to_s
  expected = "Bearer #{Rails.application.credentials.dig(:silas, :mcp_token)}"
  controller.head :unauthorized unless
    ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
end
```

**The part no other MCP server offers: a gated call parks.** When a tool's
approval policy holds a call, the endpoint doesn't error and doesn't hold the
connection — it returns

```json
{"status":"awaiting_approval","invocation_id":42,"expires_at":"…",
 "await_with":{"tool":"silas_await_decision","arguments":{"invocation_id":42}}}
```

and the call waits as rows, at zero compute, for as long as `approval_ttl`
allows. The card is in the inbox and on Slack like any other approval. The
client — which may disconnect entirely, and reconnect after your next deploy —
polls `silas_await_decision` (bounded long-poll, call it repeatedly) and gets
the real result once a named human decides: executed exactly once on approve,
`{"denied": reason}` on decline, expired if nobody answered. Every other MCP
client in the field answers its own permission prompts with an in-memory
button; this endpoint is the seam where a tool call can genuinely wait for a
person.

Each call is recorded as its own `channel: "mcp"` session, so the audit trail
reads like everything else: what was called, with what, who approved it, what
it returned.
