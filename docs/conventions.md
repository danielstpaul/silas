# Conventions and deliberate deviations

Silas follows Rails conventions by default. Where it doesn't, that's a
decision, and this page records the reasoning so the next reader doesn't have
to guess (or "fix" something load-bearing).

Style is [`rubocop-rails-omakase`](https://github.com/rails/rubocop-rails-omakase)
— Rails' own baseline, unmodified except for excluding the generated skeleton
apps (`chaos_host/`, `examples/`, `spec/dummy/`). CI enforces RuboCop,
Brakeman, bundler-audit, a Zeitwerk eager-load check, and a 90% line-coverage
floor.

## Naming and structure

### `Adapters::`, not `Engines::`

The pluggable inference backend lives at `Silas::Adapters::Base` /
`Silas::Adapters::RubyLLM`, configured with `config.adapter`. It was called
`Engines::` until 0.4, which collided with `Silas::Engine` — the Rails engine
— in the same namespace. Every comparable seam disambiguates the same way:
ActiveJob has `QueueAdapters::`, ActiveStorage has `Service::`, RubyLLM has
`Provider`. The old constants and `config.engine` still work with a
deprecation warning until 2.0.

### `class << self` vs `module_function`

Both appear, by rule, not by accident (the same split RubyLLM uses):

- **`module_function`** for pure utility modules whose methods are all
  legitimately callable — `Budget`, `MessageBuilder`, `Instructions`, `Inbox`,
  `Slack`, `StepRunner`.
- **`class << self` + `private`** where a module has real internals worth
  hiding — `Ledger` (`execute!`, `claim!`, `guarded_transaction` are not
  public API) — or holds state, like `Eval`'s scenario registry.

`module_function` publishes every method on the module, so it is the wrong
tool wherever encapsulation matters. Don't "unify" these.

### Deprecations

Everything removable goes through `Silas.deprecator`
(`ActiveSupport::Deprecation`, registered in `app.deprecators[:silas]`), so a
host silences or raises on Silas deprecations exactly as it does Rails'.
Messages name the replacement *and* the removal version; a warning you can't
act on is noise.

## Deliberate deviations

### Status columns are strings with constants, not Rails enums

`Turn::STATUSES`, `ToolInvocation::STATUSES`, `Step` states and
`approval_state` are validated strings.

Enums generate scopes and predicate methods on the model, and the ledger
performs its compare-and-swap claims through `update_all(status: "completed")`
at the SQL level — where an enum's integer/string mapping is one more thing
between the code and what the database actually holds. For a state machine
whose correctness *is* the product, the literal value in the column being the
literal value in the code is worth more than the generated sugar.

### Webhook controllers skip CSRF

`Silas::Channels::BaseController` calls `skip_forgery_protection`. No browser
session originates a webhook, so no CSRF token can exist. Each route
authenticates the request itself instead:

- Slack routes verify an HMAC-SHA256 signature with a 300-second replay window.
- Email approve/decline routes require a purpose-scoped, expiring
  `MessageVerifier` token; possession of the token *is* the credential, so CSRF
  would add nothing an attacker holding it couldn't already do.

Both are covered by request specs including the negative cases (unsigned,
wrong secret, stale, tampered, expired, wrong-purpose, replayed). The
suppression is recorded with this reasoning in `config/brakeman.ignore`. The
inbox controllers keep `protect_from_forgery`; the JSON API is
`ActionController::API` and is token-authenticated.

### Nothing is mass-assigned

There is no `Model.new(params)` or `update(params)` anywhere, and therefore no
strong-parameters ceremony. Every controller reads scalars explicitly
(`params[:input].to_s.strip`) and passes them as keyword arguments. The one
bulk value — a session's `metadata` hash on the JSON API — is assigned
explicitly to a single JSON column, so it cannot reach any other attribute.

### Indexes cover query paths, not every foreign key

`silas_memories.session_id`, `turn_id` and `superseded_by_id` are provenance
columns: written, never used in a `WHERE`. `silas_turns.job_id` is
observability. They are deliberately unindexed — an index nobody reads is a
write cost on the durable loop's hot path. The columns that *are* queried are
indexed, including the partial unique index on `silas_turns` that enforces
one active turn per session.

## Conventions worth knowing

- **Escaping**: no `raw`, `html_safe`, or `<%==` anywhere. Tool arguments,
  tool results, and model output are rendered escaped, because a framework
  that displays LLM and third-party output is the last place to hand-wave XSS.
- **Time**: `Time.current`/`Time.zone` throughout; no `Time.now` or
  `Date.today`.
- **Concerns** live in `app/models/concerns/silas/`; the engine is
  `isolate_namespace Silas` so host apps can't collide with it.
- **Trace partials** are rendered in two contexts (the inbox controllers and
  Turbo's broadcast jobs, which use the *host's* renderer). They therefore
  build engine routes through `silas_engine_path`, never bare route helpers,
  and the shared helper is registered host-wide. See
  `spec/silas/inbox/broadcasting_spec.rb`.
