# The deterministic in-process engine: pure function of (scenario, step index).
# Same role as the spike's fake model server, but injected through Silas's engine
# seam — no HTTP needed. MODEL_TURN_MS pads latency so kill windows are hittable.
class ChaosEngine < Silas::Adapters::Base
  STEPS = ENV.fetch("CHAOS_STEPS", "8").to_i
  APPROVAL_STEP = 3

  def execute_step(context, &_on_event)
    sleep(ENV.fetch("MODEL_TURN_MS", "0").to_f / 1000.0)

    # Compaction summarisation call (compact mode): deterministic summary, and
    # the sleep above keeps the kill window open across it — a kill -9 can land
    # mid-summary, which is exactly the crash the pending-row resume covers.
    if context[:compaction]
      return Silas::Adapters::Result.new(
        blocks: [ { "type" => "text", "text" => "CHAOS SUMMARY" } ],
        tool_calls: [], stop_reason: "end_turn",
        usage: { input_tokens: 1, output_tokens: 1 }
      )
    end

    i = context[:index]
    scenario = context[:turn].session.metadata["scenario"] || "default"

    tool_calls =
      if scenario == "approval" && i == APPROVAL_STEP
        [ Silas::Adapters::ToolCall.new(id: "t#{i}_gate", name: "approve_gate", arguments: { "i" => i }) ]
      elsif i < STEPS
        (0..1).map do |c|
          Silas::Adapters::ToolCall.new(id: "t#{i}_c#{c}", name: "record_row",
                                        arguments: { "i" => i, "c" => c, "turn" => context[:turn].index })
        end
      else
        []
      end

    blocks = [ { "type" => "text", "text" => "step #{i}" } ]
    tool_calls.each do |tc|
      blocks << { "type" => "tool_call", "id" => tc.id, "name" => tc.name, "arguments" => tc.arguments }
    end

    Silas::Adapters::Result.new(
      blocks: blocks,
      tool_calls: tool_calls,
      stop_reason: tool_calls.empty? ? "end_turn" : "tool_use",
      # compact mode: report a big context so the NEXT turn crosses the
      # CHAOS_COMPACT_AT threshold and compacts this one.
      usage: { input_tokens: scenario == "compact" ? 1_000 : 1, output_tokens: 1 }
    )
  end
end

Rails.application.config.after_initialize do
  Silas.configure do |c|
    c.adapter = ChaosEngine.new
    c.isolate_steps = true # the production durability configuration under test
    c.max_steps = ChaosEngine::STEPS + 2
    # Absolute-token trigger (the custom-adapter form); nil everywhere except
    # compact mode so the other gates run exactly as before.
    c.compact_at = ENV["CHAOS_COMPACT_AT"]&.to_i
  end
end
