# Changelog

## 0.6.3 (2026-07-29)

Two safety declarations were failing open, and one approval card could be
spent twice. The rest of the release is the console, the channel layer and the
docs catching up with what the framework already does.

### Fixed

- **Tool declarations now inherit — a base class silently disarmed both
  gates.** Ruby does not inherit class-level instance variables, and
  `Silas::Tool` stored all four of its declarations in them. So the ordinary
  Rails move of factoring shared declarations into a base class — a `MoneyTool`
  declaring `transactional!` and `approval :always`, with
  `class IssueRefund < MoneyTool; end` under it — left `IssueRefund` running at
  `effect_mode :at_most_once` and `approval :never`: no database transaction
  around the write, no human gate, no error and no warning. The two
  declarations the Ledger acts on both failed **open**, into their least safe
  defaults, and the transcript looked entirely normal. `param` refinements had
  the same defect, which compounds the string-default trap: a subclass lost its
  base's `param :amount_pence, :integer`, so the model was told to send a
  string and any numeric comparison in an approval lambda raised outside the
  ledger's rescue. Settings now resolve up the ancestry with the nearest
  explicit declaration winning; param refinements merge down, so a subclass can
  override one param without dropping the rest. Direct subclasses that declare
  nothing keep the documented defaults. **If your app has a tool base class,
  read `YourTool.effect_mode` and `YourTool.approval_policy` in a console
  before you deploy — that is what those tools have been running as.**
- **`approve!`, `answer!` and `decline!` are compare-and-swap — one approval
  could be spent twice.** The guard read in-memory state and the settle paths
  then wrote with a bare `update!`, so two holders of the same rendered
  approval card — two people, a double-click, a retried POST — both passed it,
  both wrote, and both reached `resume_turn!`. Each then found no invocation
  still `required` and enqueued a fresh `AgentLoopJob`: **one turn ran twice**,
  two paid model calls, the second minting `tool_call` ids the ledger has never
  seen and therefore cannot dedup. That is the double-execution the
  unsafe-queue-adapter boot guard exists to prevent, arriving instead through
  the approval path — the one path whose entire purpose is to be the safe place
  a human intervenes. A verdict now settles through an `update_all` scoped to
  `approval_state "required"` and raises naming the approver who won, rather
  than silently overwriting a decline with an approval; `resume_turn!` moves
  the turn out of `waiting`/`in_doubt` with a second compare-and-swap and
  enqueues only if it won that one, which covers the case a per-invocation
  claim cannot — two gated invocations on one step, settled concurrently, each
  legitimately winning its own row and both then seeing no remaining gate.
  Chaos on the fixed path: worker 25/25 and parked 15/15, all completed, all
  transcripts byte-identical, zero duplicate side effects.
- **The installer sent you to a doctor it had already failed.** Rails defaults
  development to the in-process `:async` queue adapter, and the doctor fails
  `:async` — correctly, because a re-enqueued continuation runs concurrently
  with the original there and double-executes steps. The install generator's
  last words were "then `bin/rails silas:doctor` to verify the whole setup", so
  the first thing the framework told a new developer was a red X for a
  condition it knew about before it printed the instruction. The generator now
  detects the adapter and prints the exact config to paste — printed, never
  written — and the doctor prints the same text beside the failure, from the
  same constant, so the two cannot drift. The doctor's unrecognised-adapter
  branch also stops reading as a style preference: a Sidekiq or GoodJob app is
  now told what it actually loses, which is `DeadJobRescuerJob` (it returns
  early unless Solid Queue is defined), so a job killed with its worker is
  never retried and a turn stranded mid-tool stays `running` with its in-doubt
  invocation unswept. It stays a warning, and the boot guard stays scoped to
  `:async`.
- **Six published claims about the guarantees were false** — all of them in the
  material a reader uses to decide whether the durability contract can be
  trusted. Chaos does not run "hundreds of times per release": `ci.yml` has no
  chaos job and `release.yml` runs only rspec, so the harness is real and
  reproducible and a human runs it. The matrix is **275 runs**, not 295 —
  `bin/full_gate` is 100 + 100 + 10 + 10 + 5 + 25 + 25, and `RESULTS.md`'s own
  table summed to 275 under the inflated total. Handoffs are **at-most-once**,
  not "exactly-once-guarded"; a crash mid-handoff parks in doubt for a person.
  `Silas::Mcp::Server` was documented as a shipped seam when nothing outside
  its specs calls `.start`, so an app cannot turn it on at all — the code stays
  because a mounted endpoint is the planned shape, and both pages now say it is
  not wired up. Two pages still read 0.5.x. `guarantees.md` also told readers
  the gate figures were the last batch in each results file: `results/*.jsonl`
  is append-only and every per-change run appends to it, so the last batch is
  whatever ran most recently. The page now says what is true — batches start
  where `run` restarts at 1, no field marks which one was a gate, and
  `chaos_host/RESULTS.md` is the record — and the rows stay unedited, including
  the inconvenient ones. `CONTRIBUTING.md` promised the chaos gate only "where
  the loop changed" against four published pages promising the full gate before
  every release; it now matches the public promise.
- **The README's `IssueRefund` example never declared its integer param.** Param
  types default to string, so the model was told to send `"6400"` and the
  example's own `input[:amount_pence] > 2_500` raised `ArgumentError` — inside
  `approval_verdict`, outside `run_tool!`'s rescue, which kills the loop job
  and (in development, where no rescuer is scheduled) strands the turn in
  `running` with no diagnostic. `docs/tools.md`, the skill and
  `templates/desk.rb` all had it right; the one place it was missing was the
  most-copied snippet in the project.
- **`docs/headless.md` named a scope helper that does not exist** (`with_scope`
  for `Silas.with_agent_scope`) and suggested `Session.where(status: "waiting")`
  — `waiting` is a turn status, and a session query for it validates fine and
  silently returns nothing. Corrected to the approval queue and parked turns,
  with both vocabularies named so the trap is visible rather than inferred.
- **A named agent asking for a tool it doesn't have raised a bare `KeyError`.**
  It now raises `Silas::Error` naming both the tool and the agent, which is
  what the operator needs to see in the log.

### Upgrading

- **Settle parked turns for your named agents before deploying this.** Named
  agents gain `ask_question` and the connection tools (below), and adding tools
  to a scope changes that scope's definitions digest — the nondeterminism guard
  refuses to resume a turn against a different agent than the one that started
  it. A turn parked under a named agent — waiting on an approval, a question,
  or an in-doubt call — is failed with `definitions_changed` when it wakes after
  the upgrade, not resumed. Clear the inbox for each named agent and let those
  turns finish first. Root-agent and subagent digests are unchanged, so their
  parked turns are unaffected.

### Added

- **Channels route to named staff.** `Silas::Channel.dispatch` hardcoded
  `Silas.agent.start` and neither first-party caller could say otherwise, so
  every Slack thread and every email woke the root agent: an app could employ
  staff with their own tools, instructions and cron and still had no way to
  send `#billing` or `billing@` to the bookkeeper. `config.channel_routes` maps
  a transport-specific key to an agent name
  (`{"slack" => {"C0BILLING" => "bookkeeper"}}`); unmatched threads wake the
  root agent, so nothing changes for an app that sets nothing. Routes are
  checked at boot against the `app/agents/` roster — a typo fails the deploy
  and names the staff that do exist, rather than raising inside a webhook,
  where Slack retries, the retry guard drops the retry, and the message is
  gone. The continuation token now carries the agent as well as the channel
  (`slack:bookkeeper:C1:ts`), and a lookup that misses the new form falls back
  to the old one, so a live thread keeps the session — and the agent — it
  already had. Only new threads route.
- **Named agents get `ask_question` and the remote connections.** A named
  agent (`app/agents/<name>/`) is staff, not a lesser agent: it can park to
  ask a person, and it can reach the MCP tools declared in
  `app/agent/connections/` — one set of credentials for the whole app,
  resolved the same way the root agent resolves them. Its scope was built by
  the same builder subagents use, which grants only `load_skill`, `run_code`,
  `remember`, `recall` and `handoff` — so the member of staff woken by its own
  Slack channel or email address was structurally the one that could not stop
  and ask, in a framework whose premise is that a turn parks for days waiting
  on a human. And the remote credentials are the app's, not the root agent's,
  yet only the root agent could spend them. `config.ask_question` governs the
  builtin exactly as it governs the root agent. `delegate` stays root-only:
  subagents belong to the root agent's turn.
- **`docs/headless.md` — Silas without the inbox.** The inbox is a mountable
  engine, not a requirement, and nothing said so. The page names the pattern —
  drive `approve!`/`decline!`/`answer!` from your own controllers, since the
  inbox, the JSON API, the Slack controller and the signed email links are four
  callers of the same three `ToolInvocation` methods — and what you take on
  instead of pretending it is free: rendering model-authored arguments, your
  own authorization, live updates (the engine's broadcast targets are internal,
  not a contract), and the real coupling, which is that
  `Channel.approval_url` mints links against `Engine.routes`. It also covers
  `Silas.with_agent_scope` for apps whose capabilities vary per user or tenant,
  with the two constraints that bite: connection credentials are paths into the
  app's own credentials rather than per-end-user OAuth tokens, and changing an
  agent's capabilities fails its parked turns loudly on resume — while teaching
  it facts does not, because memory is not in the definitions digest.
- **The console accounts for a handoff.** `Session` has carried
  `parent_session` and `child_sessions` since 0.5 and the JSON API serializes
  both, but no view read either — so the one relationship a multi-agent
  framework exists to express appeared in the inbox as a new row with a
  different agent's name, no explanation and no route back to the session that
  started it. Three places state it now: a child session names the agent that
  handed over and links to its session, the call that made a child renders that
  child in the feed at the point it happened (with its agent and its turn's
  state), and the index marks child rows with the parent's agent, so a row that
  read as a stray reads as the second half of a handoff. The pairing is
  recovered from `session_id` in the handoff's own result and accepted only
  when that session's parent is the calling session — `session_id` is a
  plausible key for any tool to return, and a lineage line that is merely
  probably true is worse than none. `handoff` is at-most-once, so a crash
  between `Session.create!` and the result leaves a colleague started with
  nothing in the trace naming it; those children are listed under the feed
  rather than dropped.
- **A render-side test for every live-update target.** Turbo addresses an
  element that must already be on the page: broadcast to an id no view renders
  and nothing raises, nothing logs, nothing updates — the trace stops moving
  while every spec stays green. That is exactly how 0.6.1's held-pill bug
  shipped, and seven of the ten targets had never been checked against a real
  render. Each is now pinned to the partial that must render it, the five
  `replace` targets additionally to that partial's root element (the only shape
  that survives a swap), and the contract runs backwards too — every
  broadcasting transition is driven with the seam captured and the emitted set
  held to the nine covered — so a target added with no view to receive it fails
  as well.

### Changed

- **The session page shows what the agent did, not the trace.** Every tool call
  rendered identically — name, status pill, a key/value table of arguments, a
  disclosure around the result — so a read that returned a row and a
  transactional write that moved money carried the same weight, and the
  sentence an operator came for had to be reassembled from the parts on every
  row. Each invocation is now one line: `issue_refund · order #4821 · GBP 64.00
  → approved by Dana · refunded`, with arguments and result behind the
  disclosure. Salience comes from effect mode, the property that says whether a
  row mattered: an idempotent call that worked is furniture, `at_most_once` is
  loud, and `transactional` earns the heaviest rule on the page, because its
  write and its ledger row commit together. A failure is loud whatever it
  touched, and so is anything still owing a person a verdict. Both readings
  ship in the DOM with a checkbox choosing between them in CSS — a broadcast
  render has no params and no reader to ask, so a choice baked into the render
  would snap back on the first replace. A settled turn also states its own
  audit: when it was asked, where it stands, how many tools ran and how many of
  them wrote. Three absences now say so out loud instead of showing as gaps — a
  turn that called no tools, a completed step that produced neither text nor a
  call, and a tool that returned nothing — because an unexplained hole in a
  feed reads as a rendering bug. `running` reads **WORKING** in the pill, the
  same word the index rail's Working group uses for the same turn; the database
  strings and the JSON API are untouched.

## 0.6.2 (2026-07-26)

The providers guide and the remaining community files.

### Added

- **`docs/providers.md` — Providers & gateways.** How a model id picks a
  provider (and why Silas stamps the resolved provider on every step row),
  the OpenRouter recipe — one key, 300+ models, slash-form ids, with cost
  lines and `compact_at` following the registry entry for the route you
  actually run — plus OpenAI-compatible gateways (LiteLLM, Vercel AI
  Gateway) via `openai_api_base`/`openrouter_api_base`, the
  Bedrock/Vertex/Azure key map, local runtimes with the honest
  cost-unavailable story, and `around_model_call` for failover. Every
  mechanical claim verified against ruby_llm 1.16 source and a live
  resolution run; Vercel endpoint details from their docs as of 2026-07-07.
  Ships in the gem; linked from the configuration reference, the README,
  and the installer's `ruby_llm.rb` initializer comment.
- **`CODE_OF_CONDUCT.md`** (Contributor Covenant 2.1), linked from
  CONTRIBUTING and the README.
- **A pull request template** mirroring CONTRIBUTING's actual gates: both
  stores, RuboCop, the chaos gate when the loop is touched, the
  templates-smoke run when generators change, and a durability-notes
  section for replay-path changes.

### Fixed

- README's status line claimed 0.5.x.

## 0.6.1 (2026-07-26)

Two live-inbox fixes found by driving real apps, a security hardening pass,
and the polished brand kit.

### Changed

- **Polished brand geometry everywhere.** Lamps sit on a shared r4.8 circle
  (proceed and held aspects now one geometry), the favicon is redrawn
  natively at 32px with a heavier housing (it reads at 16px now), and the
  wordmark lockup is cropped to the ink — re-outlined to font-independent
  paths on the new geometry. The inbox layout's favicon and header mark
  carry the new coordinates, as do the templates' landing pages.
- The docs gained real product imagery: an 18-frame park→approve→clear GIF
  captured from a genuine template-app run, the held approval card, and the
  signal board — on the site landing, inbox-and-api, and tutorial pages.

### Fixed

- **The turn pill now flips to held live.** Turbo `replace` swaps the target
  element itself, but the header's and cost line's broadcast-target ids lived
  on wrapper divs in the parent views — so the FIRST status broadcast
  destroyed the target and every later one (including the park that reads
  **held**) silently no-opped until a reload. The partials now carry their own
  root ids, with regression specs asserting a replace re-emits its target.
- **The first broadcast of a fresh worker no longer dies on lazy routes.**
  Rails 8.1's lazy route set only retries a missing url helper when the app
  routes were *just* loaded; in a worker's first Turbo render the engine's
  helper module could predate its route draw, killing the job silently
  (`undefined method 'cancel_inbox_turn_path'`). `silas_engine_path` now
  forces the draw once on miss.

### Security

- **Connections refuse credentials over plaintext http.** A connection with
  `auth:` configured and an `http://` URL to a remote host now fails loudly at
  parse time (localhost exempt; unparseable URLs with auth fail closed).
  Finding from the pre-release security audit — which otherwise confirmed the
  posture: fail-closed HMAC webhook verification with constant-time compare
  and a replay window, expiring signed approval tokens, deny-by-default
  inbox/API auth enforced at the base controllers, argv-array sandbox exec
  (no shell interpolation), timing-safe MCP token compare, restricted ERB
  bindings, no interpolated SQL, Brakeman and bundler-audit clean.

## 0.6.0 (2026-07-26)

The brand release: the Signals inbox, the docs surface (site + gem-shipped
guides + tutorial), the templates family (desk + analyst) with its anti-rot
CI gate, community files, and the framework-first README.

### Added

- **Docs for the whole surface.** New guides, all shipped in the gem:
  `tutorial` (build the refund desk outward, one primitive per chapter),
  `guarantees`, `tools`, `agents`, `memory`, `inbox-and-api`, `sandbox`,
  `evals`, `budgets`, `cancellation`, `connections`, and a full
  `configuration` reference. A docs site (Jekyll + just-the-docs, dark-first,
  Archivo/Space Mono, `early · 0.x` chip) builds from `docs/` in CI and
  deploys to Pages, with an `llms.txt` for coding agents. Brand assets
  (`brand/`, hero at `docs/img/`) now live in the repo; the hero image is
  excluded from the packaged gem.
- **Rails application templates, as a family** — `templates/desk.rb` and
  `templates/analyst.rb`, each a single CI-gated `rails new -m` script.
  `rails new desk -m
  https://raw.githubusercontent.com/danielstpaul/silas/main/templates/desk.rb`
  builds a deployable agent app from nothing: a refund desk with one tool per effect
  mode (`lookup_order` idempotent, `issue_refund` transactional behind a
  £25 approval gate, `notify_customer` at-most-once), Solid Queue **and** Solid
  Cable wired in development (the durability contract needs a real worker; live
  deltas need a cross-process cable), a keyless scripted stand-in so the first
  `bin/dev` works with zero secrets, three deterministic agent evals asserting
  the hold and the exactly-once execution, and a Signals-branded signal-board
  landing page. The template only runs the generators the gem already tests,
  and the `templates_smoke` workflow regenerates and tests an app from every
  template on each push — starters that structurally cannot rot. (eve needs
  template repos because it has no generator story; Rails has application
  templates.) **The analyst** is the second template: a scheduled reporting
  agent — `query_metrics` reads, `flag_anomaly` lands rows exactly once,
  `publish_report` holds at the signal (`approval :always`), a Monday-07:00
  schedule, and a schema-checked `final_answer` (`Turn#answer_data`). Both
  templates also wire `ANTHROPIC_API_KEY` into Kamal's secrets so the
  generated app deploys without a scavenger hunt.
- **Community files** — `CONTRIBUTING.md` (the deliberate scope no-list, the
  chaos-gate requirement, how templates are contributed), `SECURITY.md`
  (private vulnerability reporting; deny-by-default surfaces; contract
  violations count), and GitHub issue forms.
- **The gem ships its own docs, and the installer ships a coding-agent skill.**
  `docs/**` and `DEPLOY.md` are in the packaged gem, so `bundle show silas`
  gives a coding agent (or an offline human) the real reference — and the
  README's links stop 404ing for gem-only readers. `rails g silas:install` now
  also writes `.claude/skills/silas/SKILL.md`: the `app/agent/` conventions,
  the effect-mode and approval decision rules, and the ledger rules an agent
  must never violate — so a Claude Code/Codex session building on this app
  gets the framework's judgment without the human learning it first. Gemspec
  gains `documentation_uri` and `bug_tracker_uri`.

### Changed

- **The inbox wears the brand** (direction "Signals"). Dark-first — the tokens'
  base is the night palette and light is the `prefers-color-scheme` override —
  with a position-light mark, a lowercase wordmark, and one white "lamp" accent
  that never means state. The seven run states each get their aspect:
  `in_doubt` its own violet (it is neither waiting-by-design nor failed),
  `canceled` a dashed quiet (a lamp going out, not turning red), and two
  UI-only relabels — `waiting` reads **held**, `completed` reads **clear**. The
  database strings and the JSON API are untouched (`docs/conventions.md`).
- **Approvals and questions are hoisted to the top of the session** — the
  operator never scrolls a long trace hunting for the card; the trace keeps a
  one-line "held at the signal" stub in place. Live parks append their card via
  the same Turbo broadcasts; settled cards remove themselves. Tool arguments
  render as key/value rows and results collapse behind a disclosure; the
  session index groups its rail by who's blocked: **Held / Working / Filed**.
- The playground's chat page consumes the engine's colour tokens instead of
  re-hardcoding a palette, and hosts the hoisted approval/question cards above
  its transcript.

- **README reframed, framework-first** — it now mirrors eve's shape exactly:
  the mark as the logo (dark/light `<picture>`), badges, a one-paragraph
  thesis, "The filesystem is the authoring interface" with the tree, quick
  start, one minimal example, status/community/license. The hero illustration
  moved to the repo's social-preview role (its inbox panel is a designed
  idealization, not a screenshot — it shouldn't sit where users compare it to
  the real `/silas/inbox`). The docs site nav is grouped eve-style — Tutorial
  and Guarantees up top, then **Core / Advanced / Reference / About**
  sections — via build-time frontmatter injection (`site/assemble.rb`, which
  fails the build if a docs page lacks a nav entry), keeping the gem-shipped
  markdown frontmatter-free. `docs/vs-eve.md` was **factually rewritten**
  (2026-07-26): the previous revision described eve as a managed-cloud
  platform; eve is fully self-hostable, and the comparison now rests on what's
  actually different — exactly-once vs documented at-least-once, a shipped
  production inbox vs a dev TUI, memory vs none, and the transaction-boundary
  argument, date-stamped against eve 0.27.6 and framed as siblings (pick by
  stack). `docs/why-silas.md` rewritten in the same voice — you build the same
  things with Silas you'd build with any modern agent framework; the
  guarantees are where it goes further — and DEPLOY.md dropped its stale "eve
  without the bill" subtitle.

### Fixed

- The generated `config/initializers/ruby_llm.rb` no longer guards its whole
  configure block behind `ANTHROPIC_API_KEY` — keyless boots skipped the
  `use_new_acts_as` opt-in, so every demo-mode boot printed RubyLLM's legacy
  acts_as deprecation warning. A nil key assignment is inert; the block now
  always runs.

## 0.5.0 (2026-07-26)

Two new loop primitives (replay-safe compaction, ask_question), a whole-channel
generator, the adapter rebound onto RubyLLM's public single-turn seam, and
per-agent schedules. Chaos-gated: **295 kill/deploy cycles across both stores —
zero duplicate side effects, byte-identical replay** — including a new compact
mode that kills mid-summarisation and asserts the compaction claim is
exactly-once and the rebuilt provider messages are byte-identical
(`chaos_host/RESULTS.md`).

### Added

- **Per-agent schedules.** Named agents own their cron the way they own tools
  and skills: `app/agents/analyst/schedules/monday_kpis.md` is discovered as
  `agents/analyst/monday_kpis`, compiled by `silas:schedules` under a
  collision-free recurring key, and its ticks start **the analyst** — a staff
  member's schedule never wakes the root agent. `.rb` handlers resolve under
  the agent's namespace (`Agents::Analyst::Schedules::MondayKpis`).

- **`ask_question` — the agent can park to ask a human something.**
  Information, not permission: the model calls the new builtin with a
  question, the turn parks at zero compute through the same machinery as
  approvals (TTL, channel ping, resume gate), and the operator's free-text
  reply becomes the tool result the model resumes with
  (`{"answer" => "..."}`). Answer from the inbox (a question card with a text
  box replaces approve/decline) or the API
  (`POST /silas/api/v1/approvals/:id/answer {text:}`); `decline!` remains the
  refusal path, and an unanswered question expires as
  `{"answer" => nil, "note" => "question expired unanswered"}`. Channels are
  pinged only if they implement `deliver_question` — buttons are the wrong UI
  for free text, so transports without it simply leave the question in the
  inbox. Disable with `config.ask_question = false`.

  **Upgrade note:** adding a builtin changes the definitions digest, so turns
  parked across the upgrade fail loudly on resume (the nondeterminism guard
  working as designed). Settle parked turns before upgrading, or set
  `config.ask_question = false` to keep the old digest.

- **Context compaction that survives replay.** Long sessions used to grow
  until the provider rejected the prompt and the turn failed. Now, when the
  measured context passes `config.compact_at` (default 0.9 of the model's
  registry context window; set an Integer for an absolute token threshold, or
  nil to disable), Silas summarises all prior turns into a `silas_compactions`
  row and the conversation continues — the current turn is never compacted.

  The design constraint is the durability contract: replayed executions must
  see byte-identical message arrays, so a summary can never be computed at
  build time. Compaction is an *effect*, made exactly-once the way tool
  effects are — claimed compare-and-swap (unique index per session + span),
  generated once, then read deterministically from the row forever. A crash
  mid-summary leaves a pending row the resume finishes; a crash mid-step
  replays against the identical compacted history. New `compact.silas`
  instrumentation event (duration = the summarisation call). Chaos-gated with
  a dedicated mode: kill -9 during the compacting turn, including
  mid-summarisation.

### Changed

- **The `:ruby_llm` adapter no longer fights the library.** `Chat#complete`
  runs RubyLLM's whole agentic loop — model, execute tools, feed results back,
  model again — but Silas needs a single move, because the step boundary *is*
  the durability boundary. It used to get one by registering tool proxies that
  threw `RubyLLM::Tool::Halt` to abort the loop from the inside.

  Chat is now used as the builder it is (it owns model resolution, schema
  normalisation, system instructions and message construction) and execution
  drops one layer to `RubyLLM::Provider#complete` — the same call Chat makes
  internally for a single turn. Entirely public API, and the adapter got
  smaller: no `Tool::Halt`, no hunting back through `chat.messages` for the
  assistant reply, and the `before_message` streaming-timing oddity is gone in
  favour of an event Silas emits itself.

  **This removes Silas's exposure to the largest RubyLLM 2.0 breaking change.**
  2.0 deletes `Tool::Halt` precisely because the loop became caller-controlled;
  Silas no longer needs it either way. The adapter also now calls `with_tools`
  (2.0 drops the singular `with_tool`) and its schema proxy answers to both
  `params_schema` and `parameters_schema` (2.0 renames it), so the tool path is
  version-agnostic today. No behaviour change for users.

### Added

- **`rails g silas:channel <name>`** — scaffolds a whole channel, not half of
  one. Channels were reachable before (`Channel.dispatch` is a ~50-line seam)
  but the engine ships webhook routes for Slack only, so any other transport
  meant hand-rolling a controller, a route, and signature verification with no
  documented contract. The generator writes the outbound `Channel` subclass,
  a signature-verifying inbound controller, and the route that joins them —
  with the security decisions already made: verify before anything else, sign
  over the raw body, fail closed on a missing secret, and send approvals to an
  operator rather than to whoever started the session.
- **`Silas::Webhook.verify_hmac`** — the parts of webhook verification that are
  identical for every vendor (constant-time comparison, replay window,
  fail-closed on a missing secret), with the vendor's shape (`payload`,
  `prefix`, `digest`) supplied by the caller. `Silas::Slack.verify_signature`
  now delegates to it and keeps its exact v0 scheme.
- **`Silas::Channel.approval_url(invocation, action)`** — a signed, expiring
  one-click approve/decline link for *any* transport, built from the engine's
  route set and the discovered mount point, so it works from a delivery job
  with no routing scope. Raises with the fix when no host is configured rather
  than minting a dead link.
- `docs/channels.md`: the inbound/outbound contract, a per-vendor signature
  table, and a worked WhatsApp Cloud API example.

### Removed

- `demo/refund-desk` and `demo/churn-desk`. Both were copy-paste kits whose
  READMEs instructed deleting a file the generated eval still asserted on —
  broken on arrival. `examples/playground` is the example; `docs/why-silas.md`
  and `docs/vs-eve.md` now point at it.

## 0.4.0

The architecture-and-hardening release: one shipped feature that had never
worked, the naming locked down before 1.0 freezes it, and the durable loop
finally observable.

### Fixed

- **The email approval channel had never worked.** Both the approval email
  template and the confirmation page called `approval_url`/`approval_path`,
  but the route is declared inside `namespace :channels`, so the real helpers
  are `channels_approval_url`/`_path`. Rendering raised — meaning
  **`ChannelMailer#approval` blew up and the "your agent needs approval" email
  was never delivered**, and the confirmation page 500'd. If you relied on
  email approvals, you were silently never notified that a money-moving call
  was parked. Found by writing the first specs for these surfaces.

### Changed (breaking, pre-1.0)

- **The inference seam is now `Adapters::`, not `Engines::`** — and
  `config.adapter`, not `config.engine`. "Engine" meant two unrelated things
  in one namespace: the Rails engine at `Silas::Engine`, and the pluggable
  inference backend. Every comparable seam disambiguates — ActiveJob has
  `QueueAdapters::`, ActiveStorage `Service::`, RubyLLM `Provider`. Done now
  because 1.0 freezes the public API and host apps subclass this seam.
  **Nothing breaks today**: `Silas::Engines::Base`, `config.engine`, and
  `Silas.resolved_engine` all still resolve, warn through the new deprecator,
  and are removed in 2.0.
- **Notification names follow the Rails convention** `<event>.silas` (like
  `sql.active_record`). The two pre-existing events were backwards:
  `silas.step` → `step.silas`, `silas.delta` → `delta.silas`. Update any
  subscriber; `subscribe(/\.silas\z/)` now catches everything.

### Added

- **Instrumentation for the durable loop.** It emitted almost nothing before:
  a turn could start, park for a human, be rescued after a `kill -9`, breach a
  budget and finish without a single line. Ten events now — `turn`, `step`,
  `tool`, `park`, `resume`, `approval`, `budget`, `rescue`, `nondeterminism`,
  `delta` — with documented payloads that always carry `turn_id`/`session_id`,
  so a subscriber never has to join. **`tool.silas`** times the tool's own
  execution and reports how it settled (the most useful span in the system);
  **`resume.silas`** carries `parked_for` — how long the human actually took.
  `Silas::LogSubscriber` (modelled on Solid Queue's) turns them into log lines
  at operator-filterable levels: parks and rescues INFO, budget WARN, failed
  turns and nondeterminism ERROR, per-token chatter DEBUG — and stays silent
  when the rescuer did nothing.
- **`Silas.deprecator`** — an `ActiveSupport::Deprecation` registered in
  `app.deprecators[:silas]`, so hosts silence or raise on Silas deprecations
  exactly as they do Rails'. Every message names the replacement *and* the
  removal version.
- **Coverage for the four money-path surfaces that had none** (36 specs):
  `Channels::SlackController` (unsigned / wrong-secret / stale-timestamp
  requests refused end to end; retries and bot messages ignored; buttons
  settle through the same `approve!`/`decline!`),
  `Channels::ApprovalsController` (tampered, garbage, expired and
  wrong-purpose tokens refused; **GET never mutates**, so a link preview or
  scanner cannot approve a refund; a replayed link on a settled invocation
  422s), `AgentMailbox` (References → In-Reply-To → Message-ID threading, so
  replies continue rather than restart), and `ChannelMailer` (renders, shows
  the arguments, embeds two distinct absolute links whose tokens verify back).
- **Quality tooling, enforced in CI**: `rubocop-rails-omakase` (Rails' own
  style baseline, zero offenses), SimpleCov with a **90% line-coverage floor
  that fails the build** (actual: 92.5%), Brakeman and bundler-audit (clean —
  the single deliberate CSRF suppression is documented with its reasoning in
  `config/brakeman.ignore`), and a `rake zeitwerk:check` job that eager-loads
  every constant to catch naming violations lazy tests never see.
- **Dependency contract specs.** Silas reaches into Solid Queue and RubyLLM
  internals, where a rename breaks *recovery* silently. Ten specs pin them:
  the dead-process error classes the rescuer allowlists,
  `FailedExecution#retry`, the Solid Queue >= 1.2 continuations floor,
  RubyLLM's `with_schema`/`before_message`/`Tool::Halt`/model registry and the
  error classes `retry_on` names, and `resume_errors_after_advancing` staying
  false. Plus an allowed-to-fail CI canary against ruby_llm edge, for early
  warning on the 2.0 horizon.
- **`docs/conventions.md`** — the naming and structure rules (why the seam is
  `Adapters::`; the deliberate `class << self` vs `module_function` split) and
  the audited posture: nothing mass-assigned, no `raw`/`html_safe` anywhere,
  `Time.current` throughout, indexes on query paths rather than every foreign
  key. Written down so nobody "fixes" something load-bearing.

No migration. 336 specs green on SQLite and Postgres.

## 0.3.2

- **The `timeout` budget no longer counts time spent parked for approval.**
  The wall clock restarts when an approval resumes a turn, because any
  approval slower than `limits.timeout` previously made the approved resume
  *instantly* re-park on "timeout" — pathological for a gate whose whole point
  is waiting for a person (found live in the playground: a 3-minute approval
  against a 120s timeout). Timeout now bounds **active** stretches — hung
  providers, runaway loops; crash-rescue resumes keep the original clock (the
  turn was genuinely live), and cost/token budgets stay cumulative because
  they measure real spend.
- **Broadcast-rendered trace partials work in host apps.** The inbox's live
  trace renders through Turbo's broadcast jobs — i.e. the HOST's default
  renderer — where the engine-scoped `TraceHelper` and bare engine route
  helpers didn't exist, so **every broadcast render raised and the live trace
  silently never streamed in real host apps** (the gem's specs stubbed the
  dispatch seam and never rendered). The helper is now registered host-wide,
  partials build routes context-free via `silas_engine_path` (engine route
  set + discovered mount point), and four host-renderer regression specs pin
  the real path. `relative_time` is renamed `silas_relative_time` (it is now
  host-visible, and the bare name is exactly what a host app would define).
  Also new: `examples/playground` gets a customer-facing chat page that
  renders and live-streams the engine's own trace partials with zero custom
  streaming code, plus a scripted keyless demo mode (`bin/setup && bin/dev`
  with no API key).

## 0.3.1

- **Fixed: only the first scenario in a `silas:eval` run was really tested.**
  `Silas.configure` never invalidated the memoized resolved engine, so a
  second `configure` in the same process kept serving the first one — every
  eval scenario after the first silently ran the *first* scenario's script
  while still reporting pass/fail as though it hadn't. Reconfiguring now
  re-resolves both the engine and the sandbox. The gem's own specs missed this
  because the spec helper resets config between examples; a real multi-scenario
  eval suite — the production path — does not. Found by building
  `examples/playground`.
- **Automatic approvals are now recorded.** A graded gate that clears a call
  (a lambda under its threshold, an `:once` rule already satisfied) sets
  `approval_state: "approved"` with **no** `approved_by` — so the audit trail
  distinguishes "gate ran and passed automatically" (which the inbox now
  renders as *auto-approved by policy*) from "no gate at all", which stays
  `nil`. Previously both were indistinguishable on a money-moving tool.
- The generated `ruby_llm.rb` initializer opts into `use_new_acts_as`, silencing
  RubyLLM's legacy-API deprecation warning on every boot — Silas never uses
  `acts_as_*`, so the warning was pure noise. Existing initializers are still
  never touched.

## 0.3.0

- **`bin/rails silas:doctor`** — every known first-run failure mode as one
  command: provider key, queue adapter (async = red), model resolution with
  prices, migrations, tool validation, the rescuer recurring entry, the cable
  adapter for live streaming (async cable can't carry worker deltas), and
  whether the deny-by-default inbox/API auth has been wired. Exits non-zero
  on failures, so it slots into CI.
- **Hard-removed the 0.2 `:agent_sdk` config shims** — `config.auth` and
  `config.agent_sdk_*` now raise `NoMethodError` (they were warning no-ops
  for the 0.2 cycle). `config.engine = :agent_sdk` still raises the
  explanatory `BootGuardError`. Workflows now use `actions/checkout@v5`
  (Node 20 deprecation).
- **Inbox at scale + the promised top-up card.** Budget-parked turns now
  render a **"Budget reached — raise & resume"** card (the UI the 0.1.5
  changelog promised): one field, one click, `raise_budget!`, completed work
  replays from rows. The session list pages by keyset (`?before=<id>`, 50 per
  page — the old hard `limit(100)` made session 101 unreachable forever), and
  the index renders in **2 queries** instead of ~4 per card.
- **Cost accounting prices itself from RubyLLM's model registry** (1,100+
  models, refreshed upstream from models.dev) instead of a five-entry
  hand-maintained map. Steps stamp the **provider** RubyLLM resolves at
  persist time, and lookups use the two-arg `find(model, provider)` — 85/1081
  registry ids exist under multiple providers at different prices, so the
  bare lookup could silently price the wrong one. `config.model_prices` is
  now an **override map** (default `{}`) for fine-tunes, custom deployments,
  and models newer than the installed registry; unknown models stay
  `unpriced`, never a lying $0.00. Dropped the write-only
  `silas_turns.cost_microcents` column (declared since 0.1.0, never
  populated). Default model is now `claude-sonnet-4-5` — in every supported
  registry, unlike `claude-sonnet-5` (absent from ruby_llm 1.16's shipped
  registry, which would have broken first runs), and never the priciest
  model. New migration: `bin/rails silas:install:migrations db:migrate`.
- **Structured final answers.** Declare a JSON schema under `final_answer:` in
  agent.yml and the turn's answer comes back as a parsed Hash —
  `Turn#answer_data` (alongside `answer_text` for prose agents), in the API
  (`answer_data` on turns, `structured` on steps), the inbox trace, the REPL,
  and a new `assert_answer_data` eval assertion. Implemented on RubyLLM's
  `with_schema` (each provider's native structured-output dialect). The schema
  is model-visible state: it folds into the definitions digest **only when
  present** — schema-less agents keep a byte-identical digest, so turns parked
  across the upgrade never trip `NondeterminismError` (pinned by spec); a
  mid-turn schema change fails loudly by design. Structured answers replay
  into later turns' history as their JSON text (deterministic).

- **A public HTTP + SSE session API** at `/silas/api/v1` — sessions
  (create/show, `?trace=1` for the full transcript), turns (create — **409**
  while one is active — and cancel), and approvals (list / approve / decline,
  the exact same `approve!`/`decline!` as every other surface, stamped with
  `config.api_actor`). Deny-by-default via `config.api_auth`, the inbox's
  contract. `GET .../sessions/:id/stream` is server-sent events at row
  granularity (turn / completed-step / invocation changes) with
  `Last-Event-ID` resume — at-least-once, epoch-ms watermark ids, `?poll=1`
  for a curl-friendly backlog-and-close, self-closing after
  `api_stream_max_duration` with a `timeout` reconnect event. The AR
  connection is released between polls; per-token streaming remains the
  Turbo/browser feature (deltas live in the worker process; the gem takes no
  cross-process bus dependency). `Session` gains `parent_session` /
  `child_sessions` associations, and session JSON carries the lineage.

## 0.2.0

- **Token streaming, end to end.** The engine seam's `&on_event` block — dead
  code since 0.1.0 — is live: the `:ruby_llm` engine streams the model
  response (`chat.complete` with a block; the assembled message is identical
  to the sync path, so durability semantics are untouched), `StepRunner`
  coalesces text deltas into ~10Hz `"silas.delta"` notifications
  (`Silas::DeltaBuffer`) carrying the accumulated text, and two subscribers
  render them: the inbox trace (synchronous Turbo `broadcast_update_to` into a
  stable per-step target — crash-restream overwrites, never duplicates) and
  the `silas:chat` REPL (tokens print as they arrive). Deltas are decoration
  over the authoritative rows: never persisted, never fed to the model, and a
  replayed step emits none. `around_model_call` hooks keep their existing
  contract and can no longer swallow the stream.
- **Onboarding fixes.** The generated `bin/ci` can now actually fail on app
  tests (it silently swallowed them with `|| true`); the generated initializer
  shows every option the next-steps mention (`inbox_auth`, `sandbox`,
  `memory_approval`, `model_prices`, `eval_dir`, `approval_ttl`) and defaults
  to `claude-sonnet-5` instead of handing a first run the most expensive model
  with no budget set; the rescuer's `recurring.yml` entry is now **idempotent
  and environment-aware** (injected under every deployable env block —
  staging included — never blind-appended into whatever block ends the file,
  never duplicated on a re-run); a missing provider API key is caught **at
  boot** with the exact fix (warns in development, raises `BootGuardError` in
  production); and the unsafe Async-adapter warning **raises in production**,
  where running agents on it silently voids the durability contract.
- **Model-call resilience: transient provider errors retry from the
  checkpoint; nothing ever strands in `running`.** Previously a single
  429/529/timeout failed the loop job permanently and invisibly — the turn sat
  in `running` forever with no retry and no signal. Now:
  `resume_errors_after_advancing = false` on the loop job (Active Job
  Continuations otherwise swallow errors raised after a checkpoint and
  self-resume unboundedly, bypassing `retry_on` — verified against activejob
  8.1); transient classes (`RateLimitError`, `OverloadedError`,
  `ServiceUnavailableError`, `ServerError`, Faraday timeouts) retry with
  polynomial backoff + jitter and **resume from the last completed step**;
  exhaustion and permanent rejections (`UnauthorizedError`,
  `PaymentRequiredError`, …) expire pending approvals and fail the turn
  loudly. The rescuer now also sweeps **stranded turns** — a loop job that
  died with an error outside the retry list fails its turn
  (`reason: "job_failed"`) instead of leaving it running forever. Stale
  approval cards can no longer zombie-resume a failed turn (`approve!` /
  `decline!` refuse; `resume_turn!` guards).
- **The inbox now shows the audit trail it exists to provide.** Tool
  `arguments` render for every settled invocation (not just parked ones), a
  failed tool shows its recorded `error` instead of a bare red pill, and
  `approved_by` / `decline_reason` render on settled approvals — who held the
  lever, and why it moved. Active turns gain a **Cancel** button (running
  turns flag for a step-boundary cancel, parked turns cancel immediately),
  and the "N awaiting approval" badge is now a link filtering the session
  list to what needs you (`?pending=1`).
- **Web chat in the inbox.** The session page gains a composer (`POST
  .../sessions/:id/turns`) and the index a start-a-session form (with a named
  agent picker) — the browser is now a first-class conversational surface, not
  just approve/decline. Writes ride `authenticate_write!` exactly like
  approvals; a turn-in-progress renders as an inline alert; web-chat sessions
  stay `channel: nil` ("direct"), so no outbound delivery jobs are enqueued.

- **`approval :once` is now scoped to (tool, arguments), not tool name alone.**
  Name-only matching was a footgun: approving a £5 refund silently
  auto-approved a £5,000 refund later in the same session. Identical repeat
  calls still skip re-approval; different arguments park again. Graded gates
  belong in an approval lambda.
- **The ledger's checkpoint guard moved to `IsolatedExecutionState`** (from
  `Thread.current[]`, which is fiber-local) — it now follows the app's
  configured isolation level exactly like agent scopes, surviving into
  internally-created fibers where the old flag silently vanished. Nested
  ledger transactions now save/restore the guard instead of clearing it (the
  old `ensure` opened a checkpoint-guard hole for the rest of the outer
  transaction).
- **Removed the `:agent_sdk` engine** (the `claude -p` subprocess integration).
  Its differentiating rationale — running on a Claude subscription plan instead
  of API credits — was structurally unreachable: `--bare` was hardcoded and the
  engine raised without `ANTHROPIC_API_KEY` regardless of `config.auth`, so the
  OAuth path could never execute a turn. What remained was a second engine with
  weaker guarantees on every axis (exactly-once only *within* a run,
  `approval :never` tools only, fail-closed on any mid-subprocess kill) that
  made the durability contract conditional. One production path now:
  `:ruby_llm`.
  - `config.engine = :agent_sdk` raises a clear `BootGuardError` at configure
    time. `config.auth` and the `agent_sdk_*` options are warning no-ops for
    this release (hard removal in 0.3) — an existing initializer won't crash.
  - The in-process MCP server (`Silas::Mcp::Server`/`Handler`) **survives the
    cut** — it is the seam for a planned "mount your agent's tools as an MCP
    server" feature — with its own integration spec. Its bind host moved from
    `config.agent_sdk_mcp_host` to `config.mcp_server_host`.
  - New migration drops `silas_turns.cli_session_id` and
    `silas_turns.mcp_token` (the latter was write-only; tokens are minted and
    compared in memory). Run `bin/rails silas:install:migrations db:migrate`.
  - `Silas::Engines::Base.loop_ownership` is gone — every engine executes one
    model call per step under the framework-owned loop. Custom engines that
    merely inherited it are unaffected.

## 0.1.7

- **Memory — graph-shaped, not a graph database.** New `silas_memories` table:
  entity-attributed facts (`subject · attribute · content`) with provenance
  (session/turn) and **supersession** — a new fact about the same
  subject+attribute retires the old one. Two built-ins: `remember`
  (`transactional!`, **approval-gated by default** — the memory card parks in
  your inbox; `config.memory_approval = :never` opts out) and `recall`
  (on-demand subject lookup). Recent memories inject into the instructions
  snapshot (bounded by `config.memory_injection_limit`). Scopes: private
  per-agent or `shared: true` app-wide. Domain memory stays where it belongs —
  your own tables; this is for the fuzzy residue with no natural home. Edges
  are a deliberate not-yet. Upgrade-safe: tools only advertise when the
  migration has run.
- **Handoffs — staff composition without agent chatter.** New `handoff`
  built-in (advertised when `app/agents/` exists): file a self-contained brief
  that starts another named agent's linked session (`parent_session_id`),
  async by default, `await: true` for run-now-and-return-answer.
  `at_most_once!` through the ledger; refuses self-handoffs, unknown targets,
  cycles, and chains deeper than 3. Free-form agent-to-agent conversation
  remains deliberately unblessed.
- `Session#continue(enqueue: false)` for callers that drive the turn
  themselves. New migration: run `bin/rails silas:install:migrations
  db:migrate` on upgrade.

## 0.1.6

- **Named agents — the staff pattern.** An app can now employ several
  top-level agents: `app/agents/<name>/` (instructions.md, agent.yml, tools/,
  skills/), autoloaded under `Agents::<Name>`, started with
  `Silas.agent(:clerk).start(input: ...)`. Sessions are stamped with the
  agent's name and **every turn — including crash resumes — runs under that
  agent's own scope** (tools, skills, instructions, definitions digest), so a
  rescued staff member can never wake up holding another agent's tools. The
  inbox gains per-agent filter chips; `silas:chat` gains `AGENT=name`. The
  root `app/agent` is unchanged and remains the default.
- **Scope switching is now execution-isolated (concurrency fix).**
  `with_agent_scope` previously mutated global config — two Solid Queue
  threads running different agents (or a delegation racing a parallel job)
  could see each other's tools. Scopes now live in
  `ActiveSupport::IsolatedExecutionState` (per-thread *and* per-fiber —
  Falcon-safe), nestable, with the readers (`Silas.agent`, `tool_resolver`,
  `tool_definitions`, `skills`, `definitions_digest`, `instructions_dir`)
  consulting the active scope first. This also fixes a latent bug where a
  crashed *subagent* turn resumed by the rescuer would run under the ROOT
  agent's scope.

- **Approval lambdas get indifferent-access input.** Arguments are stored as
  jsonb (string keys); a lambda writing `input[:amount]` got a silent nil —
  fail-closed for gates written `nil > 50 ? park : approve`, but a silent
  always-approve for the inverse. `input` is now
  `ActiveSupport::HashWithIndifferentAccess`.
- **Brownfield-safe installer.** `silas:install` now leaves an existing
  `config/initializers/ruby_llm.rb` completely untouched (no conflict prompt —
  an accidental Y clobbered production provider config). First generator specs.
- **hermetic integration.** `config.sandbox = Hermetic.gvisor(image: ...)` is
  now a documented, spec-covered path (the companion
  [hermetic](https://github.com/danielstpaul/hermetic) gem: gVisor, Firecracker,
  hosted E2B, or hardened Docker behind one `run` call, with `trust`/`off_host?`
  as first-class axes). `sandbox_enabled?` now honors the configured backend's
  own `enabled?` (a `Hermetic.null` won't advertise `run_code`), and configuring
  a hermetic backend auto-arms its ledger guard — a sandbox exec inside a ledger
  transaction fails loud. No new runtime dependency: Silas only duck-types
  against the seam.

## 0.1.5

- **Turn cancellation.** `turn.cancel!` — a parked or queued turn settles to
  `canceled` immediately (pending approvals expire, so a late `approve!` can
  never zombie-resume it); a running turn is flagged and honored at the next
  step boundary, keeping the in-flight step's paid work. Engine-owned
  (`:agent_sdk`) turns cancel only before the subprocess starts (v1). New
  migration adds `silas_turns.cancel_requested_at`.
- **Resumable budget parks.** A turn that hits `max_cost` / `max_input_tokens` /
  `timeout` now PARKS at zero compute (state intact) instead of failing
  terminally. A human resumes it with `turn.raise_budget!(max_cost: 1.50)` —
  the top-up is recorded as a per-turn override and a fresh job replays
  completed steps from rows (no model re-calls, no re-effects), continuing
  where it left off. `bin/rails silas:chat` prompts for the top-up inline.
  New migration adds `silas_turns.budget_overrides` (run
  `bin/rails silas:install:migrations db:migrate` on upgrade). Notes: the
  timeout clock includes time spent parked — size a timeout top-up from
  elapsed wall-clock; budget parks have no TTL yet (visible in the inbox as
  waiting); an inbox top-up card is planned.

## 0.1.4

- **Fresh-app quickstart actually works.** A from-scratch install previously
  failed at its own post-install steps: the generated default model
  ("claude-sonnet-5") wasn't in ruby_llm 1.16's bundled registry, and no
  provider-key initializer was generated, so the first turn raised. The
  generator now emits `config/initializers/ruby_llm.rb` (maps
  `ANTHROPIC_API_KEY`), defaults to the registry-known `claude-opus-4-8`, and a
  missing model raises an actionable error suggesting
  `RubyLLM.models.refresh!`.
- **`silas:schedules` no longer crashes on the generator's own template.** The
  example schedule's ERB comment rendered a leading blank line the frontmatter
  parser rejected; template fixed and the parser now tolerates leading
  whitespace.
- **`bin/ci` is never clobbered.** Rails 8.1 ships a real bin/ci; the installer
  now leaves an existing one untouched and tells you to add
  `bin/rails silas:eval` to it.
- **Correct Opus 4.8 pricing.** Default `model_prices` had Opus 4.8 at $15/$75
  per MTok; it is $5/$25. Added Sonnet 4.6 and the `claude-haiku-4-5` alias.
- **ruby_llm dependency bounded `< 2`** (2.0 removes APIs the engine relies on).
- **`bin/rails silas:chat` — a terminal REPL for your agent.** The dev-loop a
  hosted platform gives you from its CLI, except there is no platform: it runs
  inside your app, tools hit your real dev database, and parked approvals prompt
  inline (`approve? [y]es / [d]ecline / [s]kip`) calling the same
  `approve!`/`decline!` as the inbox and Slack. `SESSION=id` resumes a session;
  a new message while a turn is parked steers you to the pending approvals. The
  task forces the synchronous `:inline` adapter for its own process (a REPL
  wants each turn settled before the next prompt; production still runs Solid
  Queue).

## 0.1.3

- **Ledger: parallel graded gates.** When the model emits several tool calls in
  one step, `settle!` now settles every invocation instead of stopping at the
  first one that needs approval. An ungated call (e.g. a low-risk write) runs
  immediately even when a gated sibling (e.g. a money move) parks for a human —
  it is no longer stranded behind the approval. This changes only *timing*, not
  safety: an unsettled sibling already executed on resume regardless of the
  human's approve/decline, so stopping early only delayed independent work.
  Regression test in `spec/silas/parallel_tool_calls_spec.rb`.

## 0.1.2

- **Security (email channel scaffold): approvals no longer go to the session
  initiator.** The generated `Agent::Channels::Email#deliver_approval` mailed the
  approve link to `email["from"]` — the address that started the session, which
  for a support agent is the customer, letting them approve their own gated
  request. It now routes to a configured operator (`SILAS_APPROVER_EMAIL`) and
  fails closed (sends nothing) if unset. The Slack scaffold was unaffected (its
  card posts to the team channel/thread, not the initiator).

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
