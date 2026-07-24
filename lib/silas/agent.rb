require "yaml"

module Silas
  # The parsed agent definition: app/agent/agent.yml (data-only config, eve's
  # keys) over Silas.config defaults.
  class Agent
    def self.load(root: Rails.root, dir: nil)
      dir ||= root.join("app/agent")
      path = Pathname(dir).join("agent.yml")
      new(path.exist? ? YAML.safe_load(path.read) || {} : {})
    end

    def initialize(attrs = {})
      @attrs = attrs
    end

    def model       = @attrs["model"] || Silas.config.default_model
    def description = @attrs["description"].to_s
    # Optional JSON schema for the turn's final answer (raw Hash, passed to
    # RubyLLM's with_schema). Model-visible state: folded into the definitions
    # digest when present, so a mid-turn change fails loudly.
    def final_answer = @attrs["final_answer"]
    def limits      = @attrs["limits"] || {}
    def max_steps   = limits["max_steps"] || Silas.config.max_steps
    def max_input_tokens = limits["max_input_tokens"]  # cumulative input tokens per turn
    def max_cost    = limits["max_cost"]               # dollars per turn
    def timeout     = limits["timeout"]                # wall-clock seconds per turn

    # Start a session with its first turn. channel/continuation_token let a
    # channel bind the session to an external thread (backward-compatible).
    def start(input:, metadata: {}, channel: nil, continuation_token: nil)
      session = Session.create!(metadata: metadata, channel: channel, continuation_token: continuation_token)
      session.continue(input: input)
      session
    end
  end
end
