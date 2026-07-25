# The whole thesis in one file.
#
#   transactional!  the Refund row and the ledger row that says "this tool ran"
#                   commit in ONE database transaction. Kill -9 the worker
#                   mid-write and you get exactly one refund row — never two,
#                   never zero. No idempotency key, because the effect and the
#                   dedup record live in the same database.
#
#   approval        a graded gate, as a plain lambda over the arguments:
#                   small refunds apply immediately, anything over £20 PARKS
#                   the turn at zero compute until a human approves it in
#                   /silas/inbox. The job exits; approving enqueues a fresh
#                   one that replays completed work from rows.
class Agent::Tools::IssueRefund < Silas::Tool
  description "Refund part or all of an order. Amounts over £20 require human approval."

  param :order_id, :integer, desc: "The order to refund, from recent_orders"
  param :amount_pence, :integer, desc: "Amount in pence (e.g. 1250 for £12.50)"
  param :reason, :string, desc: "Why this refund is warranted, in one short sentence"

  transactional!
  approval ->(session:, input:) { input[:amount_pence].to_i > 2000 ? :user_approval : :approved }

  def call(order_id:, amount_pence:, reason:)
    order = Order.find(order_id)

    # Guard rails belong in the tool, not the prompt: a model that miscounts
    # must not be able to over-refund.
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
