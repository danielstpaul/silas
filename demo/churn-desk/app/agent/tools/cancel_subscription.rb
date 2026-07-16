class Agent::Tools::CancelSubscription < Silas::Tool
  description "Cancel a customer's subscription. Destructive — always requires manager approval."
  param :customer_id, :integer
  transactional!
  approval :always                                 # destructive state change: never auto-fire

  def call(customer_id:)
    subscription = Subscription.find_by!(customer_id: customer_id)
    subscription.update!(status: "canceled")
    { "customer_id" => customer_id, "subscription_status" => "canceled" }
  end
end
