module Silas
  module Tools
    # Parks the turn to ask the HUMAN something — information, not permission.
    #
    # It rides the approval machinery end to end (park at zero compute, TTL
    # expiry, channel ping, the resume gate), differing only in the verdict: an
    # operator ANSWERS, and the answer text becomes the tool result the model
    # resumes with. Replay determinism is free — the answer is a persisted row
    # like any other tool result.
    class AskQuestion < Tool
      description "Ask the human operator a question and pause until they answer. " \
                  "Use when you need information only a person has. The run parks at " \
                  "zero compute until the answer arrives; the answer is returned as this tool's result."
      param :question, :string, desc: "The question, complete and self-contained — " \
                                      "the operator sees nothing but this text."
      approval :always # the park; ToolInvocation#answer!/decline! settle it

      def call(question:)
        # pending+approved would execute this, but ToolInvocation#approve!
        # refuses questions (answer! is their verdict) — reaching here is a
        # framework bug, never a user mistake.
        raise Error, "ask_question is answered, not executed — ToolInvocation#answer! settles it"
      end
    end
  end
end
