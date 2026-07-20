module Silas
  module Tools
    # Read-side of memory: on-demand subject lookup (the injected snapshot
    # carries only the most recent few — this digs deeper).
    class Recall < Tool
      description "Look up saved memories about a subject (yours + app-shared). Use before " \
                  "asking a human something the staff may already know."
      param :subject, :string, desc: "Entity ref to look up, e.g. 'author:jane'."
      idempotent!

      def call(subject:)
        memories = Memory.recall(agent_name: session.agent_name, subjects: [ subject ], limit: 20)
                         .select { |m| m.subject == subject.to_s.strip.downcase }
        { "subject" => subject, "memories" => memories.map(&:to_line) }
      end
    end
  end
end
