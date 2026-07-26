# Sandbox

Code execution is **off by default** (`config.sandbox = :none`). Configure a
sandbox and the `run_code` tool is advertised to the model automatically —
always `at_most_once!`, because an exec is an external effect.

## Built-in: `:docker`

A hardened container seam — resource-capped, network-off by default, with
knobs for image, memory, CPUs, pids, and timeout
([configuration](configuration.md)). It's honest-but-interim: a container is
weaker than a microVM, and it runs on the same host as your ledger and
`RAILS_MASTER_KEY`. Treat it as suitable for code **you** wrote, not code the
model wrote.

## Real isolation: hermetic

For untrusted or model-generated code, the companion gem
[hermetic](https://github.com/danielstpaul/hermetic) drops straight in:

```ruby
# Gemfile: gem "hermetic"   (zero runtime deps)
Silas.configure do |c|
  c.sandbox = Hermetic.gvisor(image: "python:3.12-slim")
  # or .docker / .firecracker(kernel:, rootfs:) / .hosted(:e2b, api_key:)
end
```

Two properties carry through the seam:

- **The trust axis is visible.** Every hermetic backend exposes `trust`
  (`:vendor` / `:remote` / `:vm` / `:host`) and `off_host?`, so you can refuse
  to run untrusted code on the box that holds your secrets — and pair any
  local backend with `executor:` to push execution to a dedicated sandbox
  host.
- **The ledger guard is auto-armed.** Configuring a hermetic backend loads its
  Silas shim, so a sandbox exec attempted inside a ledger transaction fails
  loudly (sandbox-backed tools must be `at_most_once!`, never
  `transactional!`).

## Bring your own

`config.sandbox` accepts any object responding to `#run` — the seam is the
contract, the backends are interchangeable.
