class Agent::Tools::IssueRefund < Silas::Tool
  description "Issue a refund for an order. Refunds over £50 require manager approval."
  param :order_id, :integer
  param :amount, :integer, desc: "Refund amount in pence."
  transactional!                                   # the Refund row + the ledger row commit together
  approval ->(session:, input:) { input["amount"].to_i > 5000 ? :user_approval : :approved }

  def call(order_id:, amount:)
    order = Order.find(order_id)
    refund = Refund.create!(order: order, amount_pence: amount)  # the money-movement row
    { "refund_id" => refund.id, "order_id" => order_id, "amount_pence" => amount, "status" => "paid" }
  end
end
