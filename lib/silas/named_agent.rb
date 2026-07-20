module Silas
  # Handle for a named top-level agent (app/agents/<name>/). Same surface as
  # the root Agent — #start plus the definition readers — so call sites don't
  # care which kind they hold. The only difference: sessions it starts are
  # stamped with the agent's name, and the loop swaps in the agent's scope
  # (tools, skills, instructions, digest) for every turn of those sessions.
  class NamedAgent
    attr_reader :scope

    def initialize(scope)
      @scope = scope
    end

    def name = scope.name

    def start(input:, metadata: {}, channel: nil, continuation_token: nil)
      session = Session.create!(agent_name: name, metadata: metadata,
                                channel: channel, continuation_token: continuation_token)
      session.continue(input: input)
      session
    end

    # Definition readers delegate to the scope's parsed agent.yml.
    def model       = scope.agent.model
    def description = scope.agent.description
    def limits      = scope.agent.limits
    def max_steps   = scope.agent.max_steps
    def max_input_tokens = scope.agent.max_input_tokens
    def max_cost    = scope.agent.max_cost
    def timeout     = scope.agent.timeout
  end
end
