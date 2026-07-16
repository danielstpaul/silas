class Agent::Tools::RefundOrder < Silas::Tool
  description "Refund an order."
  param :amount, :integer, desc: "Pence"
  approval :always

  def call(order_id:, amount:)
    { "refunded" => order_id, "amount" => amount }
  end
end
