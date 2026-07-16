class Agent::Tools::LookupOrder < Silas::Tool
  description "Look up an order's customer, item, amount, and status."
  param :order_id, :integer

  def call(order_id:)
    order = Order.find_by(id: order_id)
    return { "error" => "no order ##{order_id}" } unless order

    { "order_id" => order.id, "customer" => order.customer, "item" => order.item,
      "amount_pence" => order.amount_pence, "status" => order.status }
  end
end
