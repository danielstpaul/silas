class Agent::Tools::FindCustomer < Silas::Tool
  description "Look up a customer by email domain (e.g. \"acme.io\") or company name."
  param :query, :string, desc: "Email domain or company name"

  def call(query:)
    q = query.to_s.strip
    customer = Customer.where("domain = ? OR lower(name) LIKE ?", q, "%#{q.downcase}%").first
    return { "error" => "no customer matching #{query.inspect}" } unless customer

    { "id" => customer.id, "name" => customer.name, "domain" => customer.domain,
      "plan" => customer.plan, "seats" => customer.seats,
      "trial_ends_on" => customer.trial_ends_on&.to_s,
      "subscription_status" => customer.subscription&.status }
  end
end
