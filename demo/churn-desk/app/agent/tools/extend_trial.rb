class Agent::Tools::ExtendTrial < Silas::Tool
  description "Extend a customer's trial by N days. Low-risk goodwill — applied immediately, no approval."
  param :customer_id, :integer
  param :days, :integer
  # No transactional!/approval: an ungated, low-risk write. The graded gate below
  # (issue_credit, cancel_subscription) is what parks for a human.

  def call(customer_id:, days:)
    customer = Customer.find(customer_id)
    new_end = (customer.trial_ends_on || Date.today) + days.to_i
    customer.update!(trial_ends_on: new_end)
    { "customer_id" => customer_id, "trial_ends_on" => new_end.to_s, "extended_days" => days }
  end
end
