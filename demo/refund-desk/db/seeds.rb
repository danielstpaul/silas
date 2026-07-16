Refund.delete_all
Order.delete_all
Order.create!(id: 1042, customer: "Casey Reed",  item: "Ethiopia Yirgacheffe 1kg", amount_pence: 3800,  status: "delivered")
Order.create!(id: 2087, customer: "Jordan Vale", item: "Espresso machine EM-9",    amount_pence: 12000, status: "delivered")
Order.create!(id: 3120, customer: "Priya Shah",  item: "Cold brew kit",            amount_pence: 2400,  status: "delivered")
puts "seeded #{Order.count} orders"
