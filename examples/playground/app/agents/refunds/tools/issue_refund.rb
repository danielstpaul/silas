# The refunds specialist's own copy of the money tool — same transactional
# guarantee, same £20 gate. A named agent's tools live under its own
# directory and namespace; the staff pattern is directories, not config.
class Agents::Refunds::Tools::IssueRefund < Silas::Tool
  description "Refund part or all of an order. Amounts over £20 require human approval."

  param :order_id, :integer, desc: "The order to refund, named in the brief"
  param :amount_pence, :integer, desc: "Amount in pence (e.g. 1250 for £12.50)"
  param :reason, :string, desc: "Why this refund is warranted, in one short sentence"

  transactional!
  approval ->(session:, input:) { input[:amount_pence].to_i > 2000 ? :user_approval : :approved }

  def call(order_id:, amount_pence:, reason:)
    order = Order.find(order_id)

    if amount_pence <= 0
      return { refunded: false, error: "amount must be positive" }
    end
    if amount_pence > order.refundable_pence
      return { refunded: false, error: "only #{order.refundable_pence}p is still refundable on order #{order.id}" }
    end

    refund = Refund.create!(order: order, amount_pence: amount_pence, reason: reason)
    { refunded: true, refund_id: refund.id, order_id: order.id,
      amount_pence: amount_pence, remaining_refundable_pence: order.reload.refundable_pence }
  end
end
