class Agent::Tools::RecentOrders < Silas::Tool
  description "List a customer's recent orders, with what's still refundable on each."

  param :customer_id, :integer, desc: "The customer's id, from find_customer"

  def call(customer_id:)
    orders = Order.where(customer_id: customer_id).order(placed_at: :desc).limit(10)
    {
      orders: orders.map do |order|
        { order_id: order.id, item: order.item, amount_pence: order.amount_pence,
          status: order.status, placed_at: order.placed_at.to_date.to_s,
          already_refunded_pence: order.refunded_pence,
          refundable_pence: order.refundable_pence }
      end
    }
  end
end
