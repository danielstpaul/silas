# Keyless demo mode: a scripted engine that stands in for the model when no
# ANTHROPIC_API_KEY is set, so `bin/setup && bin/dev` works with zero secrets.
#
# It fakes ONLY the model's decisions. Everything else is real: the tools hit
# the real tables, the Ledger enforces exactly-once, the £48 refund genuinely
# parks for approval, and the answer streams token-by-token through the same
# "silas.delta" pipeline a live model uses. (This is the same trick the eval
# harness and the chaos suite use — the engine seam is one method.)
#
# A pure function of (turn input, step index), so crash-replay determinism
# holds exactly as it would with a real model's persisted rows.
class DemoEngine < Silas::Adapters::Base
  def execute_step(context, &on_event)
    input = context[:turn].input.to_s.downcase
    index = context[:index]

    if input.include?("pen tray")
      pen_tray(index, &on_event)
    elsif input.include?("lamp")
      lamp(index, &on_event)
    else
      say("(Keyless demo mode — I'm a scripted stand-in, not a model. I know two stories: " \
          "the scratched walnut pen tray and the cracked brass desk lamp, both for " \
          "ada@example.com. Set ANTHROPIC_API_KEY and restart to talk to the real thing.)", &on_event)
    end
  end

  private

  # £15 — under the gate: looks up, checks orders, refunds immediately.
  def pen_tray(index, &on_event)
    case index
    when 0 then tool("find_customer", { "query" => "ada@example.com" })
    when 1 then tool("recent_orders", { "customer_id" => 1 })
    when 2 then tool("issue_refund", { "order_id" => 2, "amount_pence" => 1500,
                                       "reason" => "arrived scratched" })
    else say("Sorry about the pen tray, Ada — I've refunded the full £15.00 to your " \
             "original payment method. It should appear within a few days.", &on_event)
    end
  end

  # £48 — over the gate: the refund call PARKS for a human. When an operator
  # approves it in /silas/inbox, the turn resumes and lands on the else branch.
  def lamp(index, &on_event)
    case index
    when 0 then tool("find_customer", { "query" => "ada@example.com" })
    when 1 then tool("recent_orders", { "customer_id" => 1 })
    when 2 then tool("issue_refund", { "order_id" => 1, "amount_pence" => 4800,
                                       "reason" => "arrived cracked" })
    else say("That's no good at all — a cracked lamp isn't what you paid for. I've put " \
             "through a full £48.00 refund; it's just been approved on our side and is " \
             "on its way back to you.", &on_event)
    end
  end

  def tool(name, arguments)
    # A real model call takes a second or two; without this pause the whole
    # turn can finish inside the gap between the redirected page rendering and
    # its websocket subscribing — and a stream you subscribe to late doesn't
    # replay. (The rows are durable either way: a refresh always shows
    # everything. This is presentation cadence, not correctness.)
    sleep 0.7
    Silas::Adapters::Result.new(
      blocks: [],
      tool_calls: [ Silas::Adapters::ToolCall.new(id: "demo_#{name}", name: name, arguments: arguments) ],
      stop_reason: "tool_use",
      usage: { input_tokens: 40, output_tokens: 15 }
    )
  end

  # Stream in small chunks with a human cadence, then return the same text as
  # the durable blocks — deltas are decoration; the row is the answer.
  def say(text, &on_event)
    text.chars.each_slice(3) do |chunk|
      on_event&.call(Silas::Event.new(type: :text_delta, payload: { text: chunk.join }))
      sleep 0.025
    end
    Silas::Adapters::Result.new(
      blocks: [ { "type" => "text", "text" => text } ],
      tool_calls: [], stop_reason: "end_turn",
      usage: { input_tokens: 60, output_tokens: text.length / 4 }
    )
  end
end
