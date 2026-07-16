class Agent::Tools::IssueCredit < Silas::Tool
  description "Issue an account credit (in pence) to a customer. Credits over £50 require manager approval."
  param :customer_id, :integer
  param :amount_pence, :integer, desc: "Credit amount in pence"
  param :reason, :string
  transactional!                                   # the Credit row + the ledger row commit together — exactly-once
  approval ->(session:, input:) { input["amount_pence"].to_i > 5000 ? :user_approval : :approved }

  def call(customer_id:, amount_pence:, reason:)
    credit = Credit.create!(customer_id: customer_id, amount_pence: amount_pence, reason: reason)
    { "credit_id" => credit.id, "customer_id" => customer_id,
      "amount_pence" => amount_pence, "status" => "applied" }
  end
end
