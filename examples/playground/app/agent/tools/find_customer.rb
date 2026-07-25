# Read-only lookup. No approval, no effect mode to think about — the default
# at_most_once! costs nothing when the tool doesn't change anything.
class Agent::Tools::FindCustomer < Silas::Tool
  description "Find a customer by email or name. Returns their id and order count."

  param :query, :string, desc: "An email address, or part of a name"

  def call(query:)
    customer = Customer.where("email = ? OR name LIKE ?", query, "%#{query}%").first
    return { found: false } unless customer

    { found: true, customer_id: customer.id, name: customer.name,
      email: customer.email, order_count: customer.orders.count }
  end
end
