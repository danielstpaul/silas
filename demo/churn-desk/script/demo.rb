# Churn Desk demo — populate the inbox to the decision point.
#
#   bin/rails runner script/demo.rb
#
# A support engineer asks the agent to credit a duplicate charge and extend a
# trial. The trial extension is low-risk and applies immediately; the £240
# credit is over the £50 gate, so it PARKS for a manager in /silas/inbox.
# Approve it there to resume the turn and issue the credit exactly once.
#
# Runs synchronously via the :inline adapter (config/initializers/silas.rb).

require Rails.root.join("db/seeds")

Silas::ToolInvocation.delete_all
Silas::Step.delete_all
Silas::Turn.delete_all
Silas::Session.delete_all
Credit.delete_all
Silas::Registry.install!

request = "Acme (acme.io) emailed — they were double-charged £240 on the Team plan in May " \
          "and are threatening to churn. Credit them £240 for the duplicate charge and extend " \
          "their trial by 14 days as goodwill."

session = Silas.agent.start(input: request)
Silas::AgentLoopJob.perform_now(session.turns.first.id)
turn = session.turns.first.reload

puts "== Churn Desk =="
puts "  session=#{session.id}  status=#{turn.status}"
puts "  #{turn.answer_text.to_s[0, 220]}"
puts
puts "Credits applied:    #{Credit.all.map { |c| "£#{'%.2f' % (c.amount_pence / 100.0)} (#{c.reason})" }.inspect}"
puts "Trial (Acme):       #{Customer.find_by(domain: 'acme.io').trial_ends_on}"
puts "Awaiting approval:  #{Silas::ToolInvocation.where(approval_state: 'required').map { |i| "#{i.tool_name} #{i.arguments}" }.inspect}"
puts
puts "Open http://localhost:3000/silas/inbox and approve the £240 credit."
