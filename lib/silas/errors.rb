module Silas
  class Error < StandardError; end

  # The :agent_sdk + OAuth footgun (PLAN.md boot guard, non-negotiable): an
  # ANTHROPIC_API_KEY in the environment would silently override subscription
  # OAuth and drain credits.
  class BootGuardError < Error; end

  # A continuation checkpoint occurred inside a ledger transaction. Checkpoints
  # raise Interrupt, which would roll back the ledger row + side effects while
  # the continuation believes progress was made (spike finding #5).
  class CheckpointInLedgerError < Error; end

  # The live tool/skill definitions diverged from the turn's snapshot digest —
  # e.g. a deploy changed the agent mid-turn. Fail loudly, never resume into a
  # different agent.
  class NondeterminismError < Error; end

  # A second turn was started while one is active for the session. The partial
  # unique index is the backstop; this is the friendly front door.
  class TurnInProgressError < Error; end

  # Sandbox misconfiguration or exec failure (fail-loud, like BootGuardError).
  class SandboxError < Error; end
  class SandboxDisabledError < SandboxError; end
end
