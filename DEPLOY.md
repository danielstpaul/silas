# Deploying Silas ("eve without the bill")

Silas is an ordinary Rails app, so it deploys to a single cheap VPS with Kamal —
no platform, no per-use bill. The one thing you MUST get right: the **Solid Queue
worker has to run**, because the durability contract (a turn surviving a crash /
deploy) depends on it. A web-only deploy will accept turns and never run them.

> Status: this is the reference configuration. It is correct by construction
> (worker wired, rescuer active, secrets injected) but has not yet been run
> against a live VPS end-to-end — that's the final launch step.

## 1. The worker must run

> **Queue adapter: use Solid Queue.** Silas's durability and exactly-once
> guarantees require a durable, serializing, DB-backed adapter. **Do not run on
> the in-process `:async` adapter** (Rails' development default) — it runs
> continuation retries on a thread pool concurrently with the original job,
> which double-executes steps and breaks exactly-once. Silas warns at boot if it
> detects the Async adapter. For scripts and single-process demos, the
> synchronous `:inline` adapter is safe (but has no durability).

`rails g silas:install` already appends the durability rescuer to
`config/recurring.yml`:

```yaml
production:
  silas_dead_job_rescuer:      # retries jobs failed by dead-worker reaping/pruning
    class: Silas::DeadJobRescuerJob
    schedule: every 30 seconds
```

Pick one way to run Solid Queue:

- **Simple (one container):** run the worker inside Puma —
  set `SOLID_QUEUE_IN_PUMA=true` (Rails 8 default plugin). Fine for a demo box.
- **Recommended (durable):** a dedicated `bin/jobs` process, so a `kill -9` of the
  worker is isolated from the web tier and recovery is observable.

## 2. Kamal config (`config/deploy.yml`)

A standard `rails new` ships a Dockerfile and `config/deploy.yml`. Add a **job
role** so the worker is its own container:

```yaml
service: my-agent
image: you/my-agent
servers:
  web:
    - 1.2.3.4          # your £5/month VPS
  job:
    hosts:
      - 1.2.3.4
    cmd: bin/jobs      # the Solid Queue worker (+ dispatcher + scheduler)

registry:
  username: you
  password:
    - KAMAL_REGISTRY_PASSWORD

env:
  secret:
    - RAILS_MASTER_KEY
    - ANTHROPIC_API_KEY        # the :ruby_llm engine authenticates with this
  clear:
    SOLID_QUEUE_IN_PUMA: false # the job role runs the worker instead

# Persist SQLite + Solid Queue on a volume if you're using SQLite (or point at Postgres).
volumes:
  - "my_agent_storage:/rails/storage"
```

Secrets (Slack signing secret / bot token, model keys) go in `.kamal/secrets`
(pulled from your env or a vault), never in the image.

## 3. Deploy

```sh
kamal setup     # first time
kamal deploy    # subsequent
```

Mid-deploy safety is built in: a turn interrupted by the SIGTERM of a rolling
deploy re-enqueues and resumes (chaos-gated). Recovery latency after a hard
crash ≈ `SolidQueue.process_alive_threshold` + the rescuer's 30s cadence.

## 4. Cost

The whole thing runs on one VPS + your model spend. The engine authenticates
with an API key for whatever provider you configure through RubyLLM. Your data
and the ledger never leave your own Postgres, and there is no Silas platform
bill or per-run metering.
