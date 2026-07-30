# Direction

*Written 2026-07-28, against Silas 0.6.2. Competitor claims come from source
and shipped docs inspected on that date — versions are named so this ages
honestly.*

---

## Decisions at a glance

| Question | Decision |
|---|---|
| What is Silas *for*? | The agent framework where the production run is the dataset — durability is the foundation, not the pitch |
| Gem, or product? | Both, in three layers: `silas` (the contract), `silas-lab` (the improvement loop), the transactional tool plane (the product) |
| Keep the gem minimal? | Yes — but "minimal" means *one contract*, not *few features* |
| Build a Ruby LiteLLM? | **No.** Take the inference seam (a provider protocol + two native adapters); leave the 102-provider fan-out to LiteLLM and consume it |
| Keep up with eve? | Hold a **defined, finite parity floor**; refuse the open-ended breadth race |
| What about Claude Managed Agents? | **Integrate, don't compete.** Anthropic's own harness is not ZDR- or HIPAA-eligible by construction — be the transactional tool plane it calls into |
| What's the bet? | Counterfactual replay → traces as datasets → trace-driven optimization |
| How do we find out if the bet is wrong? | A pre-registered test at Phase 1, written before the code |

---

## The short answer

**Durability is the foundation, not the pitch.**

Silas's asset is not that it authors agents from a directory — eve, Mastra and
half a dozen others do that, several with a platform company behind them. It's
that **the agent's execution ledger commits inside the application's own
database transaction.** Today that buys exactly-once effects. That's a good
feature. But it's one instance of a much larger property that nobody else can
structurally have:

> Every other framework's record of what the agent did lives in a store outside
> your application. Silas's lives inside it — transactional, replayable,
> cost-attributed, and joinable to the business rows the agent actually moved.

That is a *dataset*, not just an audit trail. And it is the input to the one
thing no agent framework has solved: **getting from "my agent ran in
production" to "my agent is now measurably better."**

So the direction:

> **Silas is the agent framework where the production run is the dataset, and
> the agent improves from its own history — under the same durability contract
> that already protects the money path.**

Durability was Act I. It got you a credible framework and a defensible claim.
Act II is the improvement loop, and it's a much bigger idea than Act I.

---

## What the landscape actually looks like

I inspected shipped source and docs rather than marketing pages. The picture is
less comfortable than `docs/vs-eve.md` currently implies.

### eve is no longer a peer — it's a platform, moving fast

eve at **0.27.8** (npm, inspected from the published package) ships:

- A **full evals suite** — `defineEval`, dataset fan-out, three assertion
  surfaces, LLM-as-judge, gate-vs-soft severity, Braintrust and JUnit
  reporters, `mockModel` deterministic fixtures, a CLI with exit codes.
- **Nine first-party channels** (Slack, Discord, Teams, Telegram, Twilio,
  GitHub, Linear, eve's own, Chat SDK) plus a custom-channel path.
- **Frontend SDKs for four frameworks** (Next, Nuxt, SvelteKit, Vue) with
  streaming, output schemas and HITL prompt rendering.
- A **Claude-Code-shaped harness**: `bash`, `read_file`, `write_file`, `glob`,
  `grep`, `todo`, `web_fetch`, `web_search`, `agent` delegation, `load_skill`,
  `connection_search` — with override/disable-by-filename semantics.
- **Sandbox** with credential brokering, **subagents**, **skills**,
  **MCP + OpenAPI connections**, **compaction**, **`defineState`** durable
  session state, **hooks**, **instrumentation**, **dynamic capabilities**, and
  an experimental **model-authored workflow tool** that orchestrates subagents
  from generated JavaScript inside one durable step.
- **Self-hosting** via pluggable Workflow "worlds" (`@workflow/world-postgres`).

`docs/vs-eve.md` says eve's operator surface is a dev TUI, that memory is out of
scope, and implies evals are Silas's edge. Two of those three are now wrong, and
the third understates them (`docs/guides/state.md`,
`docs/patterns/multi-tenant-memory.md`). **Fix that page before anyone reads it
next to eve's docs** — a stale competitive claim in a portfolio project costs
more credibility than the feature gap it was hiding.

What eve still does *not* have, and says so plainly in
`concepts/execution-model-and-durability.mdx`:

> "A step interrupted mid-execution re-runs, so make non-idempotent side effects
> like charges or emails idempotent, or gate them with approval."

That is at-least-once, documented. **The exactly-once claim survives contact
with eve 0.27.8.** It is the one thing in the comparison table that a platform
company cannot copy without moving into your database.

### Mastra is the shape of the product you're describing — and it's Enterprise-licensed

Mastra (`@mastra/core` **1.53.0**, CLI **1.20.2**) ships 21 documentation
sections including `agent-builder`, `agent-controller`, `studio`, `editor`,
`workspace`, `long-running-agents`, `mastra-platform`, `observability`, `evals`,
`rag`, `voice`, `browser`. The Agent Builder is a UI that builds and operates
agents, persists to `Mastra.storage`, does RBAC, multi-tenancy, model policy,
OAuth tool providers and skill registries.

It is also, in their own words, **"part of the Mastra Enterprise Edition.
Production deployments require a valid EE license."**

Read that as validation of your product instinct and a warning about the
commodity path. The agent-builder-UI idea is proven enough that the leading TS
framework monetises it. Building the same UI in Ruby, later, with no
distribution, is not a plan. Their durable agents are still beta and
workflow-memoized — at-least-once, same as everyone.

### The evaluation stack is a spectator sport

Braintrust, Langfuse, Opik, Phoenix, LangSmith all do traces → datasets →
experiments → LLM-judge scoring, and Opik ships an "Agent Optimizer." Every one
of them sits **outside** the runtime. They can observe a trace. They cannot
re-execute it against your real domain, cannot see the row the tool wrote,
cannot roll it back, and cannot tell you what the *approving human* decided.

Meanwhile DSPy and GEPA do the actual optimization — GEPA reads full execution
traces in natural language, reflects on why a candidate failed, and evolves
prompts by Pareto-aware search. Its README reports 100–500 evaluations against
5,000–25,000+ for GRPO, and open models plus GEPA beating a frontier model at
Databricks for ~90× less. But it hands you a library and expects you to supply
the harness, the dataset and the metric.

**Nobody joins the three.** The runtime, the labeled data and the optimizer live
in three different companies' products. Silas can hold all three in one process,
inside the transaction, because it already lives there.

### Anthropic ships the harness itself — and says out loud what it can't do

Claude Managed Agents (beta, `managed-agents-2026-04-01`) is Anthropic's own
agent harness plus managed infrastructure. Agent configs are persisted and
versioned; sessions pin to a version; an environment provisions a sandbox
(Anthropic's cloud, or **self-hosted on your infrastructure**); events stream
over SSE. It ships bash, read/write/edit/glob/grep, web search and fetch, MCP,
skills, multiagent threads, memory stores, credential vaults, permission
policies, compaction, prompt caching, webhooks, cron deployments, and
`user.define_outcome` — a rubric-graded iterate → grade → revise loop with a
separate grader.

That is the harness layer being commoditised by the company that sells the
model. It's the strongest validation the category will ever get, and the most
dangerous competitor in it.

It also carries, in Anthropic's own documentation, the sentence that defines
Silas's market:

> "Claude Managed Agents is stateful by design: sessions are long-running,
> resume cleanly after pauses, and store conversation history, sandbox state,
> and outputs server-side. **Because of this, Managed Agents is not currently
> eligible for Zero Data Retention or HIPAA Business Associate Agreement (BAA)
> coverage.**"

Read that carefully. It is not a gap they forgot to close — it is the direct
consequence of where the state lives, exactly the trade Silas's whole thesis is
built on. Healthcare, finance, government, and EU-data-residency workloads want
agents and cannot use CMA. The shape that serves them is the one Silas already
is: state in your database, inference to your configured provider.

And the durability story is unchanged in Silas's favour. `session.error` carries
a `retry_status`, `session.status_rescheduled` means "a transient error occurred
and the session is retrying automatically," and tool effects land in Anthropic's
sandbox — never in your transaction. Even the self-hosted sandbox only moves
*tool execution* to your infrastructure; **the agent loop and the durable state
stay on Anthropic's orchestration layer.** Two stores still can't commit
atomically. Exactly-once survives contact with Anthropic's own harness, for the
same structural reason it survives eve.

### The gateway layer is finished, and you didn't win it

LiteLLM's README lists **102 provider rows** across ten endpoint families.
Bifrost benchmarks sub-15µs overhead at 5k RPS. Portkey claims 10B tokens/day,
40+ guardrails, SOC2/HIPAA/GDPR, an MCP gateway with identity forwarding.
OpenRouter and Vercel AI Gateway sell the same shape as a service.

Building a Ruby LiteLLM means shipping and maintaining 102 provider adapters to
reach parity with a free, faster, better-funded incumbent that Silas can already
consume through one `openai_api_base` line. **Don't.** (There's a sharper answer
below — it's not "do nothing.")

### Ruby is not empty, and your dependency is becoming your competitor

`ruby_llm` **1.16.0** (June 2026) has **10.8M downloads**. It now ships
`RubyLLM::Agent` with instructions and tools, RAG, "agentic workflows",
`acts_as_chat`, a chat-UI generator, an 800+ model registry with pricing, and
provider-side batching. Silas has **6,814 downloads** and pins
`ruby_llm >= 1.0, < 2` with a gemspec comment noting 2.0 removes APIs Silas
relies on.

So: your single hard dependency is (a) climbing into your layer and (b) has a
known breaking release ahead of you. That's a real risk, and it deserves a real
answer — but not the "rebuild LiteLLM" answer.

---

## Where Silas actually wins

Four properties, and only the first is currently marketed:

1. **Exactly-once, in your transaction.** Verified by a chaos harness, and still
   unmatched at eve 0.27.8. Structural, not a feature race.
2. **The in-doubt state.** "A crash made this ambiguous, so a human decides"
   is a genuinely novel primitive. Everyone else has approved/denied. You have
   approved/denied/*we don't know*, and it parks at zero compute.
3. **The trace is in the domain database.** `Silas::Step` already stamps
   `response_blocks`, `model`, `provider`, `input_tokens`, `output_tokens`,
   `terminal`; `ToolInvocation` stamps `arguments`, `result`, `effect_mode`,
   `approval_state`, `approved_by`. That row set joins to `refunds`, `orders`,
   `invoices` — the actual outcomes. An external eval platform can only do that
   join if you ship it your business tables, and then only as a stale copy.
4. **`MessageBuilder.call(turn, upto_index: i)` already reconstructs the exact
   prompt at any step, deterministically, guarded by
   `definitions_digest`.** You built that for replay safety. It is *also*, and
   this is the important part, the primitive for counterfactual replay.

Point 4 is the one to sit with. The machinery that makes a crashed turn resume
byte-identically is the same machinery that answers **"what would Haiku have
done at step 7, and would the refund still have been correct?"** You have
already paid for it. You are not currently selling it.

---

## The architecture: three layers

This answers the gem-vs-product question directly. **Yes to the gem being
minimal — but "minimal" means *one contract*, not *few features*.**

### Layer 1 — `silas`: the contract

The gem stays bare-bones, polished, and boring in the best sense. Its job is one
sentence: **a durable agent loop whose effects land exactly once and whose every
decision is recorded as a replayable, priced row in your database.**

In scope: the loop, the ledger, the step/turn/invocation schema, the filesystem
conventions, the inference seam, the trace substrate, and the built-in tool
harness (including the parity-floor items below — a session workspace and its
file tools belong here, not in a side gem). The inbox stays as an optional
mountable engine — it's the debugger, and a framework whose selling point is
auditability shouldn't make you build the audit view.

Out of scope stays out: RAG, vector stores, more first-party channels,
component libraries. Those rows in `CONTRIBUTING.md` are right and should hold.
(One row does need rewriting — see the gateway section.)

**One deliberate change to the schema philosophy:** treat the trace tables as a
*public, documented, versioned interface*, not internal bookkeeping. Layer 2 and
every user's own analytics depend on them. Write them down like an API.

### Layer 2 — `silas-lab`: the improvement loop *(this is the new idea)*

A separate gem, optional, depending on `silas`. This is the differentiator and
the résumé centrepiece. Six capabilities, each of which is only cheap because
Layer 1 already exists:

**1. Counterfactual replay.** Take a real turn from production. Re-run it from
step *n* with something changed — a different model, an edited instruction, an
added tool, a modified skill — inside a transaction that **rolls back**. Diff
the two trajectories: which tools were called, what arguments, what it cost,
what it would have written. Every other framework would have to fake your
database to do this. Silas rolls back a real one.

*This is the flagship demo. "Here is a refund the agent got wrong. Here is the
same conversation replayed against three models and two prompts, with real tool
calls against real rows, all rolled back, scored, and diffed." Nobody can show
that.*

**2. Traces → datasets.** Turn production sessions into eval cases
automatically. Silas already has the eval DSL and a scripted engine; the missing
piece is generating scenarios *from* real turns instead of hand-writing them.

The unfair advantage here: **the approval ledger is a free labeled preference
dataset.** `approval_state`, `approved_by`, and the decline reason record a
human's verdict on a specific agent action, with full context, in production, at
zero annotation cost. That is the exact data everyone else pays labellers for —
and it exists because you built approvals for safety, not for ML.

**3. Evaluation at scale.** Take today's deploy-gate DSL to a real harness: fan
out across datasets, run N seeds, score deterministically and by judge, compare
runs, track regressions over time, and publish the frontier. `docs/evals.md` is
already a good foundation — it needs breadth and a comparison surface.

**4. Model policy and routing.** Per-step model selection driven by the cost and
outcome data the ledger already stamps: cheap model for retrieval steps,
frontier model for the step that touches money, automatic downgrade when the
evals say the cheap one holds. This is the honest version of the "gateway" idea
— **routing and accounting, not provider fan-out.**

**5. Optimization.** A Ruby implementation of reflective, Pareto-aware prompt
and skill evolution in the GEPA lineage, operating on *your* traces with *your*
metric, with counterfactual replay as the rollout mechanism and the eval harness
as the fitness function. Optimizes instructions, skills, and tool descriptions —
the text parameters Silas already treats as files. A gem that rewrites
`app/agent/instructions.md` and opens a PR with the eval delta attached is a
genuinely striking artifact.

**6. Distillation export.** Traces are already message-shaped. Export
fine-tuning JSONL filtered to *successful, human-approved* turns — then close
the loop by evaluating the distilled model with the same harness that produced
its training data.

### Layer 3 — the product: the transactional tool plane

The original framing here was "a multi-agent builder/harness." **Claude Managed
Agents killed that version of the idea**, and the replacement is better.

Building a builder means competing with n8n, Dify, Flowise, Mastra EE — and now
with Anthropic's own harness, which has the model, the sandbox, versioned agent
configs, cron deployments, multiagent threads, vaults, and a rubric-graded
outcome loop. In Ruby, later, solo, that is not a plan.

But notice what CMA and eve both *require you to supply* and neither can
provide: a place for consequential effects to land safely. CMA's docs say the
sandbox is where tools run and that non-idempotent work needs an approval gate;
eve's say to make side effects idempotent yourself. Both are excellent
exploratory harnesses — sandboxes, file tools, code execution, web access,
long-horizon autonomy — and both stop at your transaction boundary.

So Silas should not compete with the harness. It should be the plane the harness
calls into:

> **Bring your own harness. Silas is where the consequential effects land —
> exactly once, behind your approvals, in your database, with the audit trail
> your regulator asks for.**

The exploratory half runs wherever it's best (CMA's sandbox is already better
than Silas's Docker seam will ever be); the consequential half runs in Rails.
Two seams make this work, and CMA supports both:

- **Custom tools.** CMA emits `agent.custom_tool_use`, *your* orchestrator
  executes it, and you reply with `user.custom_tool_result` over the stream you
  already hold. A Silas app is a natural orchestrator: the call lands in the
  Ledger, hits the approval gate, commits in your transaction, and the result
  goes back. That gives a CMA agent exactly-once effects, which CMA cannot give
  itself.
- **Remote MCP.** CMA connects to MCP servers over HTTPS, with credentials held
  in a vault and injected after egress.

**The semantics for both already exist; the transport does not.**
`Mcp::Handler#call_tool` already creates a `ToolInvocation` and drives it through
`Ledger.execute_invocation!`, so a remote `tools/call` gets the full
exactly-once, effect-mode, and approval machinery today. But `Mcp::Server` is a
raw `TCPServer` on an ephemeral port, scoped to a single turn and step, plain
HTTP, token-in-URL — built to hand a spawned local `claude` CLI a socket, not to
be addressed by anything outside the box. Turning it into a durable,
engine-mounted, session-scoped HTTPS endpoint with real auth is a well-scoped
piece of work, and it is the single highest-leverage thing on this list: it makes
Silas useful to every harness in the market instead of asking anyone to switch.

This is also a far better wedge than a builder. It doesn't ask a team to adopt a
Ruby framework for their whole agent stack — only for the part where money
moves, which is the part they're most nervous about anyway.

Keep the dogfood, but as a reference app rather than the product: a real Rails
app in this repo (the `examples/playground` and `chaos_host` precedent is right)
where a CMA or eve agent does the exploring and a Silas agent owns the ledger.

---

## On RubyLLM and the gateway question

You asked specifically about taking over `ruby_llm` and building a Ruby
LiteLLM. The answer splits, because the two halves have opposite economics.

**Don't build the provider fan-out.** 102 providers, ten endpoint families,
per-provider drift forever, against free incumbents that are faster and better
funded. You'd spend a year to arrive at worse. Silas already reaches all of them
through OpenAI-compatible base URLs (`docs/providers.md` documents this well).
LiteLLM/OpenRouter/Bifrost are *substrate*. Consume them.

**Do take the inference seam.** The risk is concrete: a `< 2` pin against a
dependency whose 2.0 removes APIs you rely on, which is simultaneously growing
its own `RubyLLM::Agent`. The fix is small and you're most of the way there:

- Harden `Silas::Adapters::Base` into a **documented, spec-tested provider
  protocol** — the thing an adapter must satisfy to be replayable, priced, and
  step-addressable. Contract tests, not a wrapper.
- Ship a **first-party thin adapter speaking two protocols natively**: Anthropic
  Messages and OpenAI Chat/Responses. Two, not 102 — and via those two plus
  OpenAI-compatible gateways you reach essentially everything.
- Keep `ruby_llm` as **an** adapter, not **the** adapter. It's excellent and its
  registry is genuinely useful. It just shouldn't be able to break you.

You need this anyway for Layer 2. Step-level model control, honest per-step
token and cost accounting, and deterministic replay are exactly the places a
general-purpose client fights you.

**This means revising `CONTRIBUTING.md`.** The current scope table says:

> | Provider abstraction, model routing, token counting | RubyLLM's job. One inference seam, no wrapping. |

Under this direction that's half wrong. Provider *abstraction* stays out.
Model *routing* and token/cost *accounting* move firmly in — they're not
plumbing, they're the product. Rewrite the row rather than quietly contradicting
it; the no-list is a credibility asset precisely because it looks decided.

---

## The parity floor: what "keeping up with eve" means

"Don't compete on surface area" is right about the race and wrong as a blanket
rule, so here is the distinction it hides.

**Table stakes are not surface area.** Their absence is disqualifying; their
presence is not differentiating. If a Rails engineer evaluating Silas hits
"wait, the agent can't write a file?", they never reach the exactly-once
argument at all. The moat is worthless if nobody gets far enough to stand on
it. So there *is* a floor to hold, and holding it is a different activity from
racing eve feature-for-feature.

What you cannot do is track them item-for-item. eve is a funded team shipping
weekly; a solo project loses that race arithmetically. The only sustainable way
to keep up is to be **structurally cheaper per feature** — and Rails genuinely
is, for a large fraction of eve's surface. Where it isn't, don't play.

### The classification

| eve surface | Silas today | Verdict |
|---|---|---|
| Session filesystem + `read_file`/`write_file`/`glob`/`grep` | **Nothing.** `run_code` shells into an *ephemeral* sandbox; there is no persistent per-session workspace for a file to survive in. | **Table stakes. The biggest real gap.** |
| `todo` durable task list | Nothing | **Table stakes** — cheap (a JSON column), and it visibly improves long-task behaviour |
| `web_fetch` / `web_search` | Nothing | **Table stakes**, near-free |
| Typed durable session state (`defineState`) | Memory (triples, approval-gated) covers a different need | **Cheap parity** — a JSON column and an API |
| OpenAPI connections | MCP client + server + connections | **Cheap parity**, high value per hour |
| Evals: dataset fan-out, gate/soft severity, reporters, run comparison | Scenario DSL, assertions, rubric grader, deploy gate | **Converges with Phase 2** — this *is* the roadmap |
| Credential brokering into the sandbox | No | Worth stealing; medium cost. CMA's version is sharper — secrets substituted at egress, so the sandbox only ever sees a placeholder |
| Versioned agent configs, sessions pinned to a version | `definitions_digest` **fails** a turn whose definitions changed | **Worth borrowing outright.** Failing loudly is safe but hostile; CMA versions the agent and pins the session, so running work finishes on its old config while new sessions get the new one. Rails is good at versioned rows |
| Declarative per-tool permission policy (`default_config` + overrides) | Per-tool `approval` lambdas | Silas's is more powerful; CMA's is friendlier for the common case. Add the declarative form over the lambda |
| Rubric-graded outcome loop (`user.define_outcome`) | Eval DSL + `final_answer` schema | Now **table stakes**, not differentiation — cheap to add on the existing pieces (see Phase A2) |
| Nine first-party channels | Slack, email, generator | **Deliberate no** — vendor-API drift forever, and Rails gives no discount |
| Frontend SDKs for four frameworks | Mounted engine + Turbo + JSON API/SSE | **Already ahead** for a Rails audience; document the API-plus-SPA path and stop |
| Deployment product, Workflow "worlds" | Kamal, Solid Queue, your database | **Already ahead** — inherently self-hosted |
| Model-authored dynamic workflows | No | **Deliberate no** — experimental even at eve |
| Sandbox as microVM | Docker seam + hermetic | Honest gap, already stated in the docs |
| Compaction, subagents, skills, MCP, instrumentation, hooks | All present | At parity or better (compaction is replay-safe, which theirs need not be) |

### The gap that isn't really about eve

The top row is the one to act on, and notice what it actually is. eve's sandbox
**owns a per-session filesystem**, seeded from `agent/sandbox/workspace/**`, with
a lifetime decoupled from the durable loop. Silas's sandbox is ephemeral per
invocation. So "add five file tools" is the wrong framing — without a persistent
session workspace there is nowhere for a file to persist *to*, and the tools are
meaningless.

That's a real chunk of architecture. It is also **exactly what Layer 3 requires**:
a builder agent that writes `app/agent/tools/*.rb` across several turns cannot
work without it. So this isn't keeping up with eve. It's building the product
you already wanted, and the parity is a side effect.

Which is the test for everything on this list: **does the Rails-native answer to
the underlying need cost you less than it costs eve?** Turbo versus four
frontend SDKs — yes, enormously. Kamal versus a deploy product — yes. A JSON
column versus a state subsystem — yes. Nine vendor channel integrations — no,
identical cost, no discount, infinite maintenance. Play where the discount is.

### The tripwire

Revisit the deliberate-no rows only on evidence, not on anxiety. Concretely: a
real user says they cannot adopt Silas without it. Three unrelated people asking
for the same channel beats any amount of reading eve's release notes and feeling
behind.

**One thing to keep clearly in view:** none of the parity floor differentiates
Silas. Finishing it means people stop bouncing before they reach the argument —
it does not itself make an argument.

---

## Roadmap

Two tracks, run in parallel, because the bet and the floor want different hours.

**Track A is the bet.** Risky, thinking-heavy, unproven. It gets your best
hours and the pre-registered test in the next section.

**Track B is the floor.** Well-understood, low-risk, mostly mechanical. It
fills the hours where Track A is blocked on thinking rather than typing. It has
a **definition of done** — that's the entire point of writing it out. When the
list ships, the floor is held and the track closes. It does not become a
standing commitment to chase eve's changelog.

### Phase 0 — clear the debt (days, both tracks blocked on none of it)

Fix `docs/vs-eve.md` against eve 0.27.8. Revise the `CONTRIBUTING.md` scope row.
Document the trace schema as a public interface. Small, and all three are
credibility.

### Track A — the improvement loop

**A1 — the replay engine (0.7).** Counterfactual replay: re-run a real turn from
step *n* with a changed model/prompt/tool, in a rolled-back transaction, and
diff the trajectories. Expose it as `silas:replay` and as an inbox action
("replay this turn with…"). The highest-leverage thing in the whole plan — it
converts machinery you already own into the feature nobody else can build.

**A2 — datasets and the eval harness (0.8).** Traces → eval cases. Approval
ledger → labeled preference dataset. Fan-out running, judge scoring, run
comparison, regression tracking. Ship `silas-lab` as its own gem here.

**A3 — the inference seam (0.9).** Adapter protocol with contract tests,
first-party Anthropic + OpenAI adapters, per-step model policy, real
cost/latency/quality accounting.

**A4 — the optimizer (1.0).** GEPA-lineage reflective optimization over your
traces, using A1 for rollouts and A2 for fitness. Output: a PR against
`app/agent/` with an eval delta. Distillation export alongside.

### Track B — the parity floor

**B0 — the durable MCP endpoint.** Promote `Mcp::Server` from an ephemeral
per-turn `TCPServer` to an engine-mounted, session-scoped HTTPS endpoint with
real auth. The exactly-once semantics behind it already exist; this is transport
work. It moves to the front of the track because it is what makes Silas useful
to CMA and eve users without asking them to switch frameworks — the Layer 3
wedge.

Then: session workspace → file tools (`read_file`, `write_file`, `glob`, `grep`)
→ `todo` → `web_fetch`/`web_search` → typed session state → OpenAPI connections.
Then stop.

**One scope reduction, courtesy of CMA.** The session workspace was justified
partly by Layer 3 needing a builder agent that writes files across turns. With
Layer 3 re-scoped to the tool plane, that justification weakens: the exploratory,
file-heavy, sandboxed work can be delegated to a harness whose sandbox is already
better than anything Silas will build. Keep the file tools — they're table stakes
for anyone using Silas standalone — but **do not chase sandbox parity**, and
size the workspace to "good enough to author and inspect files," not "a rival to
a per-session microVM." That is the most useful practical consequence of CMA
existing.

### Then — the product

The tool-plane app (Layer 3): B0's endpoint grown into a deployable Rails app
where any harness's consequential effects land, with the reference app showing a
CMA or eve agent exploring while a Silas agent owns the ledger. It needs B0 to
exist at all and A1–A4 to have its second act (the improvement loop as a product
surface), which is why it is last rather than numbered.

The 1.0 story writes itself: *the durability contract, plus the loop that makes
the agent better.*

---

## Judging A1: a pre-registered test

Everything above rests on counterfactual replay being genuinely striking rather
than merely clever. That judgement cannot be made after building it — by then
you have a stake in the answer, and "does this feel magic?" reliably returns
yes to the person who wrote it. So the criteria go here, now, while nobody
cares about the outcome. **If you find yourself revising this section after
seeing results, that is the finding.**

### Two checks that come before the code

**Day 0 — write the demo transcript first.** Before implementing anything,
write the one-page transcript you want to show: exact commands, exact output,
faked. If you cannot write a page that makes *you* want to run it, the feature
does not exist and no implementation will rescue it. This costs an afternoon
and can kill the phase outright. It also becomes the spec — build toward the
transcript, not toward an API.

**Day 1 — the null test.** Replay a real production turn with *nothing*
changed. It must reproduce the original byte-identically. This is nearly free
(the chaos harness already asserts byte-identical replay) and it validates the
mechanism rather than the story. If the null test fails, counterfactual replay
is not merely unmagical — it is unsound, and A1 stops here until it isn't.

Two strong signals, neither requiring the real implementation.

### The known failure mode: divergence

The thing most likely to make replay feel unconvincing is not performance or
ergonomics. It is that **once you change the model at step 7, step 8's input
differs, so the trajectories diverge and you are no longer comparing like with
like.** A diff that silently compares two increasingly unrelated runs is worse
than no diff — it's confidently wrong.

Design for this from the start: divergence is a *first-class output*, not a
bug. The replay should report where the runs parted company and how far they
had drifted by the end. "These two agreed through step 9 and split at the
refund amount" is a usable finding. An undifferentiated wall of diff is not.

### Pre-registered numbers

Run the built engine against **ten real turns you already know went wrong**.
Decide these thresholds now:

| Dimension | Test | Kill below |
|---|---|---|
| **Friction** | Replay a production turn against a different model | One command + one flag. More than that and it's a library, not an instrument. |
| **Latency** | 10-step turn, 3 variants, wall clock | 60 seconds. Past that you'll stop reaching for it. |
| **Non-obviousness** | Of 10 known-bad turns, how many surfaced a cause you would *not* have gotten from reading the inbox transcript? | 3/10. Below that, the transcript was already enough and replay is decoration. |
| **Decision change** | Of those, how many changed what you actually shipped — a prompt edit, a model swap, a tool fix? | 2. An instrument that never changes a decision is a toy. |
| **Unprompted reuse** | Two weeks later, count invocations made while doing real work, not while testing the feature | 5. Zero is the loudest possible result. |

Non-obviousness is the one that matters most and the one you'll be most tempted
to fudge. Guard it: **write down what you think the cause is *before* running
the replay**, then compare. Without that, hindsight makes everything look
predicted.

### Outside eyes, and the specific tell

You cannot judge your own demo. Show it to five Rails engineers who have
shipped an LLM feature and would use this in anger.

The signal is not "that's cool" — people are polite about other people's side
projects. **The tell is whether they immediately ask a specific question about
their own system.** "Could I replay the turn where our agent double-charged?"
is signal. "Nice, how long did that take to build?" is noise. Count the
unprompted specific applications; three or more out of five is a real result.

### Separating a wrong idea from wrong packaging

If it lands flat, the diagnosis matters more than the verdict, because the two
failures have opposite responses:

- **"I'd use this if it also did X"** → packaging. The thesis holds; keep
  going and fix the ergonomics.
- **"Interesting, but I'd just read the logs / add a print statement"** →
  substance. The transcript is already sufficient for their debugging, and
  replay is solving a problem they don't have. That is the thesis failing, and
  the honest response is to fall back to Layer 1 as a durability framework and
  drop Act II.

The second outcome is survivable and cheap at A1. It is expensive at A4. That
asymmetry is the entire reason replay is sequenced first.

**What this test does not cover:** it judges replay as a *debugging instrument*.
A4 needs it to also work as a *rollout mechanism* for optimization — a different
bar, where batch throughput and cost per rollout dominate and none of the five
criteria above apply. A pass here is not a green light for the optimizer.

---

## How this reads as a portfolio

You framed this as demonstrating seven years of ML infrastructure and platform
work. Mapped honestly:

**ML infrastructure at industry scale** — currently the weakest evidence in the
repo, and Layer 2 hits all five of the named sub-areas directly. *Model
deployment*: routing and model policy with real cost accounting. *Model
evaluation*: the eval harness, judges, regression gates, run comparison. *Data
processing*: the traces → datasets → training-data pipeline. *Debugging*: the
inbox plus counterfactual replay, which is the ML-infra debugging story told
properly. *Fine-tuning*: distillation export with a closed evaluation loop.

**Design, architecture, testing and launching products** — already the repo's
strongest evidence, and it's genuinely strong: the ledger state machine, the
write-once `terminal` column, the compaction-before-messages ordering, the
`definitions_digest` guard, a chaos harness that `kill -9`s live agents hundreds
of times per release with results committed to the repo. Layer 3 adds the
launched-product half.

**State-of-the-art GenAI** — currently competent (tools, MCP, skills, subagents,
compaction, memory, structured output) but not distinctive; every framework has
these. The optimizer, LLM-as-judge at scale, and distillation are where this
pillar becomes distinctive rather than table-stakes.

The one-line version, which is the version that matters: **"I built the agent
framework where production runs are the training data, and proved the loop is
safe enough to move money."**

---

## Honest notes

- **Layer 2 is a research-flavoured bet.** Counterfactual replay and
  trace-driven optimization are less charted than durable execution. A1 is the
  cheap test, and the pre-registered criteria above are what "cheap test"
  actually means — without them the bet never gets falsified, it just gets
  rationalised.
- **The cut is between Track A and everything else, not between features and
  no features.** Track B is real work that has to happen. But when the two
  tracks compete for the same hour, Track A wins — a project that finishes the
  parity floor and never ships the improvement loop is a worse-funded eve,
  which is the one outcome with no path to winning.
- **6,814 downloads.** The moat is real but nobody is standing on it yet. Layer
  1 needs a handful of real users hitting real crashes before the durability
  claim moves from "chaos-verified" to "battle-tested." The tool plane helps
  here twice over: it is also a distribution strategy, because it puts the
  ledger in front of teams without asking them to switch frameworks.
- **The `ruby_llm` relationship is a genuine fork in the road.** Handled as
  above (protocol + two native adapters, ruby_llm still supported) it stays
  friendly and you keep the ecosystem. Framed as "taking over ruby_llm" it
  becomes a fight with the most-adopted gem in Ruby AI, run by someone shipping
  faster than you. Take the seam, not the war.
- **Exactly-once still only covers effects in your database.** That limit is
  stated honestly in `docs/why-silas.md` and it must stay stated. It's also
  exactly why Layer 2 works: the effects are rows, so replay can roll them back.
- **The CMA read could go the other way, and it's worth naming.** The bet is that
  "harness elsewhere, effects in Rails" is a shape teams want. The alternative is
  that they accept at-least-once plus idempotency keys, keep everything in one
  vendor, and never reach for a second system — in which case the tool plane is a
  product nobody asks for. The cheap test is the same shape as A1's: build B0, put
  it in front of someone already running CMA in anger, and see whether the
  exactly-once pitch survives them shrugging and saying "we just use an
  idempotency key." The ZDR/HIPAA cohort is the hedge — those teams have no
  shrug available.
- **Anthropic's non-eligibility is a snapshot, not a moat.** "Not *currently*
  eligible" is the actual wording. If CMA ships a ZDR-compatible mode, the
  regulated-market argument narrows to the transaction boundary alone — which is
  still real and still structural, but it's one argument instead of two. Don't
  build the positioning solely on their compliance gap.
