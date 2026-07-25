# Deterministic scripted engine (the gem-level equivalent of the spike's fake
# model server): pure function of (turn index, step index), records every call.
class FakeEngine < Silas::Adapters::Base
  attr_reader :calls

  def initialize(&script)
    @script = script
    @calls = []
  end

  def execute_step(context, &_on_event)
    @calls << { turn_index: context[:turn].index, step_index: context[:index],
                message_count: context[:messages].size,
                roles: context[:messages].map { |m| m[:role] } }
    @script.call(context)
  end
end

module EngineScripts
  module_function

  def result(blocks:, tool_calls: [], stop_reason: nil)
    Silas::Adapters::Result.new(
      blocks: blocks,
      tool_calls: tool_calls,
      stop_reason: stop_reason || (tool_calls.empty? ? "end_turn" : "tool_use"),
      usage: { input_tokens: 10, output_tokens: 5 }
    )
  end

  def tool_call(id, name = "record", **arguments)
    Silas::Adapters::ToolCall.new(id: id, name: name, arguments: arguments.stringify_keys)
  end

  # N steps with one tool call each, then a terminal text step.
  def n_tool_steps_then_done(n)
    lambda do |context|
      i = context[:index]
      if i < n
        result(blocks: [ { "type" => "text", "text" => "step #{i}" } ],
               tool_calls: [ tool_call("t#{context[:turn].index}_s#{i}") ])
      else
        result(blocks: [ { "type" => "text", "text" => "done" } ])
      end
    end
  end
end
