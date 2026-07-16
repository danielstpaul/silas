module Silas
  # A subagent's capability bundle — its own tools, skills, config, and digest,
  # built by the Registry from app/agent/subagents/<name>/. The nested run swaps
  # these in as the active globals for the duration of the delegation.
  AgentScope = Data.define(:name, :dir, :agent, :resolver, :definitions, :digest, :skills)
end
