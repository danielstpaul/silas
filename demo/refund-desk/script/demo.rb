# Silas refund-desk demo — populate the inbox to the decision point.
#
#   bin/rails runner script/demo.rb
#
# Leaves two sessions:
#   • Casey  (£38  → under the £50 gate) → COMPLETED, one refund auto-issued.
#   • Jordan (£120 → over the gate)      → WAITING, issue_refund parked for a
#     human. Approve it in the inbox at /silas/inbox to resume the turn.
#
# Runs synchronously via the :inline adapter (configured in development.rb).

require Rails.root.join("db/seeds") # reset orders

Silas::ToolInvocation.delete_all
Silas::Step.delete_all
Silas::Turn.delete_all
Silas::Session.delete_all
Refund.delete_all
Silas::Registry.install!

def run(label, input)
  session = Silas.agent.start(input: input)
  Silas::AgentLoopJob.perform_now(session.turns.first.id)
  turn = session.turns.first.reload
  puts "  #{label.ljust(22)} session=#{session.id}  status=#{turn.status}"
end

puts "Running the refund desk…"
run "Casey  £38  (auto)",  "Hi, Casey here — order 1042, the beans arrived stale. Can I get a refund please?"
run "Jordan £120 (parks)", "Jordan here, order 2087 — the espresso machine arrived with a cracked casing. I'd like a refund."

puts
puts "Refunds issued:      #{Refund.all.map { |r| "order #{r.order_id} £#{'%.2f' % (r.amount_pence / 100.0)}" }.join(', ')}"
puts "Awaiting approval:   #{Silas::ToolInvocation.where(approval_state: 'required').map { |i| "#{i.tool_name} £#{'%.2f' % (i.arguments['amount'].to_i / 100.0)}" }.join(', ')}"
puts
puts "Open http://localhost:3000/silas/inbox and approve Jordan's refund."
