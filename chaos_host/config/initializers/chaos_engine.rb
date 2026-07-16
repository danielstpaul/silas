# The deterministic in-process engine: pure function of (scenario, step index).
# Same role as the spike's fake model server, but injected through Silas's engine
# seam — no HTTP needed. MODEL_TURN_MS pads latency so kill windows are hittable.
class ChaosEngine < Silas::Engines::Base
  STEPS = ENV.fetch("CHAOS_STEPS", "8").to_i
  APPROVAL_STEP = 3

  def execute_step(context, &_on_event)
    sleep(ENV.fetch("MODEL_TURN_MS", "0").to_f / 1000.0)

    i = context[:index]
    scenario = context[:turn].session.metadata["scenario"] || "default"

    tool_calls =
      if scenario == "approval" && i == APPROVAL_STEP
        [ Silas::Engines::ToolCall.new(id: "t#{i}_gate", name: "approve_gate", arguments: { "i" => i }) ]
      elsif i < STEPS
        (0..1).map do |c|
          Silas::Engines::ToolCall.new(id: "t#{i}_c#{c}", name: "record_row", arguments: { "i" => i, "c" => c })
        end
      else
        []
      end

    blocks = [ { "type" => "text", "text" => "step #{i}" } ]
    tool_calls.each do |tc|
      blocks << { "type" => "tool_call", "id" => tc.id, "name" => tc.name, "arguments" => tc.arguments }
    end

    Silas::Engines::Result.new(
      blocks: blocks,
      tool_calls: tool_calls,
      stop_reason: tool_calls.empty? ? "end_turn" : "tool_use",
      usage: { input_tokens: 1, output_tokens: 1 }
    )
  end
end

Rails.application.config.after_initialize do
  Silas.configure do |c|
    c.engine = ChaosEngine.new
    c.isolate_steps = true # the production durability configuration under test
    c.max_steps = ChaosEngine::STEPS + 2
  end
end
