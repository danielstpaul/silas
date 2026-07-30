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
definitions digest: if the remote server changes its toolset, parked turns
from before the change fail loudly on resume (`NondeterminismError`) instead
of resuming against a different toolset. Settle parked turns before pointing a
connection at a changed server.

## Testing

`config.mcp_client_factory = ->(connection) { fake_client }` injects a fake
client per connection — the seam the gem's own specs use.

## The other direction — not wired up yet

`Silas::Mcp::Server` is an in-process HTTP server that hosts your agent's tools
for outside MCP clients, and `config.mcp_server_host` is its bind host. **You
cannot turn it on.** Nothing in the gem starts it — the class is exercised by
its own specs and nothing else — so serving your tools as MCP is not a feature
you can use today. The code stays because a mounted endpoint is the planned
shape; until that ships, treat this direction as absent.
