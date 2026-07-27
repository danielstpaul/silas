# Headless Silas

The inbox is a *mountable* engine, not a requirement. Don't mount it and you
have the whole durable runtime — loop, ledger, approvals, memory, evals — with
no screens of ours in your app. You build the operator surface; Silas keeps
the guarantees.

This is the shape to reach for when the person approving things is **your
user, not your ops team**: a product where "review what the agent wants to
do" is a first-class feature of your own UI, styled and worded like the rest
of it.

## The whole approval lifecycle is on the model

The inbox controllers are thin. Everything they do, you can do:

```ruby
invocation = Silas::ToolInvocation.find(id)

invocation.approve!(by: current_user.email)   # resumes the parked turn
invocation.decline!(reason: "wrong customer", by: current_user.email)
invocation.answer!(text: "yes, refund the delivery charge", by: current_user.email)
```

`answer!` is the reply to an `ask_question` park — information, not
permission. Each of these settles the invocation, records the actor, and
resumes the turn. The mounted inbox, the JSON API, the Slack controller and
the email approve/decline links are simply four callers of the same three
methods; yours is a fifth.

For the queue itself:

```ruby
session.pending_approvals          # what this session is parked on
Silas::ToolInvocation.where(approval_state: "required")   # the whole queue
Silas::Turn.where(status: "waiting")                      # parked turns
```

Note the two status vocabularies: a **Turn** is
`queued/running/waiting/in_doubt/completed/failed/canceled`, while a
**Session** is only `active/archived`. Parked work is a turn in `waiting`.

Nothing about parking is UI-coupled: a turn parked for approval holds at zero
compute until one of those methods is called, whatever calls it.

## What you take on

Four things the engine was doing for you:

- **Rendering.** Arguments, results, the transcript, cost lines. The
  invocation carries `tool_name`, `arguments`, `result`, `approval_state` and
  its turn/session associations — you decide what an operator sees. Note that
  a tool's arguments are model-authored text: render them **escaped**, the
  way the engine's views do.
- **Authorization.** `config.inbox_auth` and `api_auth` guard *engine*
  routes. Your controllers are yours — apply your own policy, and remember
  that approving is a privileged action even when reading isn't.
- **Live updates.** The engine's Turbo broadcasts target its own DOM ids. If
  you want live traces, broadcast from your own views; the `Broadcastable`
  concern's targets are engine-internal and not a public contract.
- **Approval links in channels.** `Silas::Channel.approval_url` mints signed,
  expiring one-click links against **engine routes**
  (`Silas::Engine.routes.url_helpers`), so email and Slack approve/decline
  depend on the engine being mounted. Going fully headless with channel
  approvals means minting your own signed links to your own routes;
  `Channel.token_for` / `Channel.verify_token` are the signing seam, so you
  keep the token semantics (expiry via `approval_ttl`, no session state in
  the URL) without the routes.

## Mount it anyway, for the engine room

Headless and mounted are not exclusive, and the most useful arrangement is
usually both:

- **Your UI is the front office** — the approval moment your user actually
  touches, in your product's voice.
- **The mounted inbox is the engine room** — the full technical history,
  every step, every tool call, every cost, for when someone needs to know
  exactly what happened. Mount it behind staff-only auth
  (`config.inbox_auth`) and link into it from your admin.

You get a bespoke operator experience without rebuilding the audit trail, and
support questions have somewhere to be answered.

## Per-execution scopes, if capabilities vary

If different users, teams or tenants need *different* tools, skills or
instructions, note that Silas resolves those through the active scope, not
process-global config:

```ruby
Silas.with_agent_scope(scope) { ... }   # per-thread AND per-fiber
```

An `AgentScope` carries `name`, `dir`, `agent`, `resolver`, `definitions`,
`digest` and `skills` — every model-visible capability. It exists for named
agents and subagents, and `Silas.scope_for_session` resolves a session's
scope from its `agent_name` on every turn, so scoped capabilities survive
parking and resumption.

Constraints worth knowing before you build on this:

- **Credentials are paths, not values.** Connections resolve
  `credential: crm.token` against `Rails.application.credentials` at call
  time — designed for *your* app's credentials, not per-end-user OAuth
  tokens. Per-user credentials need a tool of your own that reads them;
  `Tool#session` is the context the Ledger injects, so the session is where
  you hang "whose account is this".
- **Changing capabilities fails parked turns, by design.** The definitions
  digest is a nondeterminism guard: a turn parked before its tools changed is
  *failed* on resume rather than resumed against a different agent. The
  digest is per-scope, so scoped agents don't invalidate each other — but
  within a scope, settle parked work before rolling a capability change out.
- **Memory is not in the digest.** It covers tool schemas, skill names and
  descriptions, and `final_answer` — so teaching an agent new *facts* is safe
  for parked turns, while changing its *tools* is not. If you build an
  end-user-facing way to steer an agent, prefer memory for the frequent path.
- **Named-agent scopes don't include connection tools.** A scope's resolver
  is built from its own directory's tools plus builtins; remote MCP tools are
  wired into the root agent only.
