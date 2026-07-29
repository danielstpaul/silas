# Channels

A channel puts your agent somewhere people already are — Slack, email, WhatsApp,
Discord, SMS, your own app's webhook — without changing the agent itself. The
same tools, the same approvals, the same ledger. Only the surface changes.

```bash
bin/rails generate silas:channel whatsapp
```

That scaffolds both halves and the route that joins them. The rest of this page
is the contract they implement, so you can fill in the three TODOs correctly and
know what you're getting for free.

---

## The two halves

A channel is inbound and outbound, and they are deliberately separate: inbound is
a web request, outbound is a background job. They meet at one name.

```
app/agent/channels/whatsapp.rb                        outbound  Agent::Channels::Whatsapp
app/controllers/agent/channels/whatsapp_controller.rb inbound   Agent::Channels::WhatsappController
config/routes.rb                                      POST /agent/channels/whatsapp
```

**Identity is the filename.** `whatsapp.rb` defines `Agent::Channels::Whatsapp`,
sessions started through it carry `channel: "whatsapp"`, and Silas uses that
string to find the class again at delivery time. Rename the file and the channel
is renamed; delete it and the channel is gone.

The webhook controller lives in **your app**, not the engine, because only your
app knows the vendor's signature scheme and payload shape. Slack is the one
exception — Silas ships its routes and verification because it ships Slack's
whole dialect.

---

## Inbound: verify, key, dispatch

```ruby
class Agent::Channels::WhatsappController < ActionController::Base
  skip_forgery_protection          # no browser session -> no CSRF token can exist
  before_action :verify_webhook!   # ...so the signature IS the authentication

  def create
    Agent::Channels::Whatsapp.dispatch(
      thread_key: params[:conversation_id].to_s,
      input: params[:text].to_s,
      metadata: { "whatsapp" => { "conversation_id" => params[:conversation_id] } }
    )
    head :ok
  rescue Silas::TurnInProgressError
    head :ok
  end
end
```

`dispatch` is the whole inbound API. It maps the external thread to a session and
then calls the ordinary public API — `<agent>.start` for a new thread,
`session.continue` for a reply. There is no channel-specific loop.

Three things to get right:

**The thread key must be stable.** The same conversation must produce the same
key every time, or every message starts a new session and the agent has no
memory. Use the vendor's conversation or thread id, never a per-message id. Keys
are namespaced by channel *and* agent (`whatsapp:bookkeeper:abc123`), so neither
two channels nor two staff members sharing a transport can collide.

**Sign over the raw body.** `request.raw_post`, never re-serialized params —
re-serializing changes the bytes and the HMAC no longer matches. See
[Verification](#verification) below.

**One active turn per session is an invariant, not a queue.** A reply that
arrives while the agent is still working raises `Silas::TurnInProgressError`. The
generated controller answers `200` so the vendor stops retrying; if dropping the
message matters for your transport, buffer it or tell the user.

Metadata is stored on the session and shown in the inbox, so keep it small and
free of secrets. It exists so outbound knows where to reply.

### Routing: which agent wakes

By default an inbound thread wakes the root agent. `config.channel_routes` sends
it to a [named agent](agents.md#named-agents--the-staff-pattern) instead — data
only, one entry per destination:

```ruby
# config/initializers/silas.rb
config.channel_routes = {
  "slack" => { "C0BILLING" => "bookkeeper" },   # Slack channel id
  "email" => { "billing@shop.test" => "bookkeeper" }
}
```

The outer key is the transport's filename identity (`slack`, `email`, and for a
generated channel, whatever you named the file). The inner key is whatever that
transport calls a destination. Both shipped channels read it for you: Slack
matches the channel the message arrived in, email matches every recipient
address — To, Cc, and the forwarding headers Action Mailbox itself routes on —
first match wins, case-insensitively. Anything unmatched wakes the root agent.

The session is stamped with the agent's name, so **every** turn on that thread —
including crash resumes weeks later — runs under that agent's tools, skills,
instructions, and definitions digest.

A custom channel opts in with one argument:

```ruby
Agent::Channels::Whatsapp.dispatch(
  thread_key: message[:from],
  input: message.dig(:text, :body).to_s,
  agent: Silas::Channel.route_for("whatsapp", message[:to]),
  metadata: { "whatsapp" => { "to" => message[:from] } }
)
```

**A route naming an agent that doesn't exist fails the boot that installs it**,
listing the staff that do exist. That is deliberate: `Silas.agent(name)` raises
on an unknown name, and finding that out at dispatch time would 500 the webhook
— which for Slack means a retry, which the retry guard drops, which means the
message is gone. If a bad name is assigned *after* boot, dispatch does not
raise: it logs the error and wakes the root agent, which is where that thread
went before routing existed.

Routing changes how continuation tokens are derived — `whatsapp:abc123` became
`whatsapp:agent:abc123`. Sessions that predate the change keep working: a lookup
that misses the new form falls back to the old one, so a live thread carries on
in the session it already has (with the agent it already had — a conversation
does not change hands mid-thread). New threads route normally.

### Verification

`Silas::Webhook.verify_hmac` handles the parts that are identical everywhere —
constant-time comparison, the replay window, and **failing closed when no secret
is configured**. You supply the vendor's shape:

```ruby
Silas::Webhook.verify_hmac(
  secret:    Rails.application.credentials.dig(:silas, :whatsapp, :signing_secret),
  signature: request.headers["X-Signature"],
  payload:   request.raw_post,   # what they signed
  timestamp: request.headers["X-Signature-Timestamp"],
  prefix:    "sha256=",          # what they put before the digest
  digest:    :hex                # :hex, or :base64 for Shopify/Twilio
)
```

Vendors differ only in three places:

| Vendor | `payload` | `prefix` | `digest` |
|---|---|---|---|
| Slack | `"v0:#{timestamp}:#{body}"` | `"v0="` | `:hex` |
| GitHub | raw body | `"sha256="` | `:hex` |
| Shopify | raw body | `""` | `:base64` |

Omitting `timestamp:` disables replay protection — a captured request can then be
re-sent forever. If your vendor doesn't send one, that's worth knowing rather
than defaulting past.

---

## Outbound: answers and approvals

```ruby
class Agent::Channels::Whatsapp < Silas::Channel
  def deliver_answer(session:, text:)
    # post `text` back to session.metadata["whatsapp"]
  end

  def deliver_approval(session:, invocation:)
    approve = Silas::Channel.approval_url(invocation, :approve)
    decline = Silas::Channel.approval_url(invocation, :decline)
    # send those two links to an OPERATOR
  end
end
```

You never call these. `ChannelDeliveryJob` does, from `after_commit` callbacks —
`deliver_answer` when a turn completes or fails, `deliver_approval` the moment a
tool parks. Both run **off the durable loop**, which is the important part: a
transport outage retries the delivery without re-running a single tool or
touching the ledger. Raising here is safe. It costs a retry, not a duplicate side
effect.

Delivery is claimed compare-and-swap on a marker column (`answered_at`,
`notified_at`) and released if your method raises, so a retry re-attempts rather
than double-sending. A duplicate ping is the worst case; it is never a ledger
violation.

### Approval links

`Silas::Channel.approval_url` mints a signed, expiring one-click link that works
in any transport — a WhatsApp message, a Discord embed, an SMS. Possession of the
link is the credential, so it needs no session and no login, and it expires with
`config.approval_ttl` (7 days by default).

It needs a host, and never guesses one — a hostless approval link is a dead link:

```ruby
config.action_mailer.default_url_options = { host: "yourapp.com" }
```

> **Send approvals to an operator, never to the requester.**
> For a customer-facing channel, `session.metadata` describes the person who
> messaged in. Sending them the approve link lets them approve their own refund.
> Deliver to your ops destination instead, and **fail closed** when it isn't
> configured — no destination means no approval, not a silent one. The generated
> channel does this; keep it.

Slack is different only because it can do better: it renders real Approve/Decline
buttons via Block Kit, handled by the engine's own actions webhook. Every other
transport uses the signed link.

---

## What you get for free

Everything that makes the agent durable is already there, because a channel is a
trigger, not a runtime:

- **Crash-safe turns.** Kill the worker mid-conversation; the turn resumes where
  it stopped, and no tool runs twice.
- **Approvals that park at zero compute.** A parked turn holds no worker, no
  memory, no tokens. It can wait days.
- **The inbox.** Every channel session appears at `/silas/inbox` with its full
  trace — you can watch and approve a WhatsApp conversation from the operator UI
  without building anything.
- **Budgets, cancellation, evals, memory.** All unchanged.

A channel is also **not** in the definitions digest — it's a transport, not a
model-visible capability — so adding or changing one never fails a parked turn
with `NondeterminismError`.

---

## Worked example: WhatsApp Cloud API

```bash
bin/rails generate silas:channel whatsapp
bin/rails credentials:edit
```

```yaml
silas:
  whatsapp:
    signing_secret: <your app secret>
    operator: "+441234567890"
    token: <your permanent access token>
    phone_number_id: "123456789"
```

Meta signs the raw body with your app secret and prefixes `sha256=`:

```ruby
# app/controllers/agent/channels/whatsapp_controller.rb
def verify_webhook!
  ok = Silas::Webhook.verify_hmac(
    secret: Rails.application.credentials.dig(:silas, :whatsapp, :signing_secret),
    signature: request.headers["X-Hub-Signature-256"],
    payload: request.raw_post,
    prefix: "sha256="   # Meta sends no timestamp header: no replay window
  )
  head(:unauthorized) unless ok
  ok
end

def create
  message = params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
  return head(:ok) unless message && message[:type] == "text"

  Agent::Channels::Whatsapp.dispatch(
    thread_key: message[:from],            # the sender's number: stable per conversation
    input: message.dig(:text, :body).to_s,
    metadata: { "whatsapp" => { "to" => message[:from] } }
  )
  head :ok
rescue Silas::TurnInProgressError
  head :ok
end
```

```ruby
# app/agent/channels/whatsapp.rb
class Agent::Channels::Whatsapp < Silas::Channel
  def deliver_answer(session:, text:)
    send_text(to: session.metadata.dig("whatsapp", "to"), body: text)
  end

  def deliver_approval(session:, invocation:)
    operator = Rails.application.credentials.dig(:silas, :whatsapp, :operator)
    if operator.blank?
      Rails.logger.warn("[Silas] no operator configured — approval #{invocation.id} not delivered")
      return
    end

    send_text(to: operator, body: <<~MSG)
      Approval needed: #{invocation.tool_name}
      #{JSON.pretty_generate(invocation.arguments)}

      Approve: #{Silas::Channel.approval_url(invocation, :approve)}
      Decline: #{Silas::Channel.approval_url(invocation, :decline)}
    MSG
  end

  private

  def send_text(to:, body:)
    credentials = Rails.application.credentials.silas[:whatsapp]
    uri = URI("https://graph.facebook.com/v20.0/#{credentials[:phone_number_id]}/messages")
    response = Net::HTTP.post(
      uri,
      { messaging_product: "whatsapp", to: to, type: "text", text: { body: body } }.to_json,
      "content-type" => "application/json",
      "authorization" => "Bearer #{credentials[:token]}"
    )
    # Raise on failure: ChannelDeliveryJob releases its claim and retries.
    raise Silas::Error, "WhatsApp send failed: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
  end
end
```

Point Meta's webhook at `https://yourapp.com/agent/channels/whatsapp` and restart
— `app/agent/` registers at boot.

---

## Why Silas ships one channel and a generator

Slack is first-party because it ships a whole dialect: signature scheme, Block
Kit approvals, an interactive-actions webhook. Every other transport is a
different vendor's API drifting on its own schedule, and a framework that
promises to keep six of those working is a framework that breaks.

The generator is the leverage instead. It gets the security decisions right —
signature-first, raw body, fail closed, operators not requesters — and leaves the
vendor's three variables to you.

If you build one worth sharing, open a PR against this page.
