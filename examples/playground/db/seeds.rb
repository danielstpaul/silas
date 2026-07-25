# Tinker & Co's shop data. Deliberately small and legible — you should be able
# to read the whole store in one screen and then check the agent's arithmetic.
[ Refund, Order, Customer ].each(&:delete_all)

# Explicit ids: the evals script the model's tool ARGUMENTS statically, so the
# fixture has to be reproducible. Without this, re-seeding walks the
# autoincrement forward and yesterday's eval refers to an order that no longer
# exists — which fails as a tool error, not as an assertion.
ada = Customer.create!(id: 1, name: "Ada Whitfield", email: "ada@example.com")
raj = Customer.create!(id: 2, name: "Raj Patel", email: "raj@example.com")

Order.create!(id: 1, customer: ada, item: "Brass desk lamp", amount_pence: 4800,
              status: "delivered", placed_at: 12.days.ago)
Order.create!(id: 2, customer: ada, item: "Walnut pen tray", amount_pence: 1500,
              status: "delivered", placed_at: 5.days.ago)
Order.create!(id: 3, customer: ada, item: "Linen notebook (x3)", amount_pence: 2700,
              status: "shipped", placed_at: 2.days.ago)

Order.create!(id: 4, customer: raj, item: "Cast iron bookends", amount_pence: 3200,
              status: "delivered", placed_at: 9.days.ago)
Order.create!(id: 5, customer: raj, item: "Fountain pen ink", amount_pence: 900,
              status: "delivered", placed_at: 3.days.ago)

puts "Seeded #{Customer.count} customers, #{Order.count} orders."
puts %(Try: "Hi, I'm ada@example.com — the brass desk lamp arrived cracked.")
puts "  (£48 is over the £20 gate, so that one parks for approval in /silas/inbox)"
