Credit.delete_all
Charge.delete_all
Subscription.delete_all
Customer.delete_all

acme = Customer.create!(name: "Acme Corp", domain: "acme.io", plan: "Team", seats: 12,
                        trial_ends_on: Date.new(2026, 2, 12))
Subscription.create!(customer: acme, plan: "Team", monthly_pence: 24000, status: "active")
# The duplicate: two identical £240 charges on May 3, minutes apart.
Charge.create!(customer: acme, amount_pence: 24000, charged_on: Date.new(2026, 4, 3), description: "Team plan — April")
Charge.create!(customer: acme, amount_pence: 24000, charged_on: Date.new(2026, 5, 3), description: "Team plan — May")
Charge.create!(customer: acme, amount_pence: 24000, charged_on: Date.new(2026, 5, 3), description: "Team plan — May (duplicate)")
Charge.create!(customer: acme, amount_pence: 24000, charged_on: Date.new(2026, 6, 3), description: "Team plan — June")

globex = Customer.create!(name: "Globex", domain: "globex.com", plan: "Starter", seats: 3,
                          trial_ends_on: Date.new(2026, 8, 1))
Subscription.create!(customer: globex, plan: "Starter", monthly_pence: 4900, status: "active")
Charge.create!(customer: globex, amount_pence: 4900, charged_on: Date.new(2026, 6, 1), description: "Starter plan — June")

puts "seeded #{Customer.count} customers, #{Charge.count} charges, #{Credit.count} credits"
