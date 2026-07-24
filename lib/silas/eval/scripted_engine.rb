module Silas
  module Eval
    # The productized FakeEngine: a pure function of context[:index] that lets an
    # eval script the MODEL's decisions while the REAL Ledger runs the REAL tools —
    # so assertions see a genuine transcript.
    class ScriptedEngine < Silas::Engines::Base
      attr_reader :calls

      def initialize(steps)
        @steps = steps
        @calls = []
      end

      def execute_step(context, &_on_event)
        i = context[:index]
        @calls << { index: i }
        spec = @steps[i]
        return terminal("OK.") unless spec

        Silas::Engines::Result.new(
          blocks: spec[:blocks],
          tool_calls: spec[:tool_calls],
          stop_reason: spec[:tool_calls].empty? ? "end_turn" : "tool_use",
          usage: { input_tokens: 10, output_tokens: 5 }
        )
      end

      private

      def terminal(text)
        Silas::Engines::Result.new(blocks: [ { "type" => "text", "text" => text } ],
                                   tool_calls: [], stop_reason: "end_turn",
                                   usage: { input_tokens: 1, output_tokens: 1 })
      end
    end
  end
end
