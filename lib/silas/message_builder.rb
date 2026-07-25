module Silas
  # Rebuilds the provider conversation deterministically from persisted rows —
  # the rows ARE the transcript (no separate events table in v0.1). Replayed
  # executions must produce byte-identical message arrays, so nothing here may
  # read mutable state or the clock.
  module MessageBuilder
    module_function

    # Canonical provider-agnostic shape; adapters map it to their wire format.
    #   { role: "user", content: "..." }
    #   { role: "assistant", content: [ {type:, ...blocks} ] }
    #   { role: "tool", tool_call_id:, content: {...} }
    # NOTE: always fresh queries, never cached associations — this runs inside
    # a live loop where rows were created moments ago on the same objects, and
    # a memoized empty `turn.steps` silently erases the model's own history.
    def call(turn, upto_index:)
      messages = []

      # A completed Compaction row replaces turns 0..up_to_turn_index with its
      # persisted summary. Reading the ROW keeps this deterministic: the
      # summary was generated once (Compactor's CAS claim) and never
      # recomputed, so same rows -> same array, compacted or not.
      compaction = Compaction.latest_for(turn)
      floor = -1
      if compaction
        messages << { role: "user", content: compaction_preamble(compaction) }
        floor = compaction.up_to_turn_index
      end

      Turn.where(session_id: turn.session_id).order(:index).each do |prior|
        next if prior.index <= floor
        break if prior.index >= turn.index

        messages << { role: "user", content: prior.input }
        messages.concat(step_messages(prior, upto_index: nil))
      end

      messages << { role: "user", content: turn.input }
      messages.concat(step_messages(turn, upto_index: upto_index))
      messages
    end

    # Pure function of the row — no clock, no counts of anything mutable.
    def compaction_preamble(compaction)
      "[The earlier part of this conversation was summarised to stay within " \
        "the context window. Summary of everything before this point:]\n\n" \
        "#{compaction.summary}"
    end

    def step_messages(turn, upto_index:)
      Step.where(turn_id: turn.id).order(:index).each_with_object([]) do |step, acc|
        next unless step.completed?
        next if upto_index && step.index >= upto_index

        # The settled invocations are the ledger's source of truth for what the
        # model actually invoked. Reconstruct the assistant's tool_use blocks
        # from them (not from step.response_blocks, which can drift when the
        # model emits parallel tool calls) so every tool_result replayed below
        # has a matching tool_use by construction — the provider requires it.
        settled = ToolInvocation.where(step_id: step.id).order(:id)
                                .select { |inv| inv.status == "completed" || inv.status == "failed" }

        acc << { role: "assistant", content: assistant_blocks(step, settled) }
        settled.each do |inv|
          acc << { role: "tool", tool_call_id: inv.tool_call_id, content: inv.result }
        end
      end
    end

    # Text comes from the model's own blocks; tool_use blocks are rebuilt from
    # the settled invocations so the assistant message and the tool results that
    # follow are always a matched set (same ids, same count). A structured
    # (final_answer) block replays as its JSON text — deterministic (same rows
    # -> same string), and providers need message content, not our block type.
    def assistant_blocks(step, settled)
      text = Array(step.response_blocks).filter_map do |b|
        case b["type"]
        when "text"       then b
        when "structured" then { "type" => "text", "text" => JSON.generate(b["data"]) }
        end
      end
      tools = settled.map do |inv|
        { "type" => "tool_call", "id" => inv.tool_call_id,
          "name" => inv.tool_name, "arguments" => inv.arguments || {} }
      end
      text + tools
    end
  end
end
