class Agent::Tools::RecentCharges < Silas::Tool
  description "List a customer's recent charges, newest first (read-only)."
  param :customer_id, :integer

  def call(customer_id:)
    Charge.where(customer_id: customer_id).order(charged_on: :desc, id: :desc).limit(6).map do |charge|
      { "id" => charge.id, "amount_pence" => charge.amount_pence,
        "charged_on" => charge.charged_on.to_s, "description" => charge.description }
    end
  end
end
