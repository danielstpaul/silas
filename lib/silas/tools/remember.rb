module Silas
  module Tools
    # Built-in, advertised when memory is enabled and the table exists. Writes
    # are APPROVAL-GATED by default (config.memory_approval = :always) — a
    # memory card parks in the inbox before anything persists, eve's
    # user-approved-memory pattern done Rails-style. transactional! — the
    # memory row and the ledger row commit together, exactly once.
    class Remember < Tool
      description "Save a durable memory for future sessions. Use for stable preferences and " \
                  "facts worth keeping (\"author:jane · report_format: prefers CSV\"), never for " \
                  "transient task state. Same subject+attribute supersedes the old value."
      param :subject, :string, desc: "Entity this is about, e.g. 'author:jane' or 'retailer:kdp'."
      param :content, :string, desc: "The fact, one plain sentence."
      param :attribute, :string, desc: "Optional slot name (enables supersession), e.g. 'report_format'."
      param :shared, :boolean, desc: "true = visible to ALL agents (app scope); default private to this agent."

      transactional!
      approval ->(session:, input:) do
        Silas.config.memory_approval == :never ? :approved : :user_approval
      end

      def call(subject:, content:, attribute: nil, shared: nil)
        memory = Memory.remember!(
          agent_name: session.agent_name, subject:, content:, attribute:,
          scope: shared ? "app" : "agent",
          turn: session.turns.order(:index).last
        )
        { "remembered" => memory.to_line, "scope" => memory.scope }
      end
    end
  end
end
