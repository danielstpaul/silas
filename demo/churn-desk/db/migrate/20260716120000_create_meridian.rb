class CreateMeridian < ActiveRecord::Migration[8.1]
  def change
    create_table :customers do |t|
      t.string :name, null: false
      t.string :domain, null: false
      t.string :plan, null: false
      t.integer :seats, null: false, default: 1
      t.date :trial_ends_on
      t.timestamps
    end
    create_table :subscriptions do |t|
      t.references :customer, null: false
      t.string :plan, null: false
      t.integer :monthly_pence, null: false
      t.string :status, null: false, default: "active"
      t.timestamps
    end
    create_table :charges do |t|
      t.references :customer, null: false
      t.integer :amount_pence, null: false
      t.date :charged_on, null: false
      t.string :description
      t.timestamps
    end
    # The money-movement row: an issue_credit is exactly-once because THIS row and
    # its ledger row commit in one transaction.
    create_table :credits do |t|
      t.references :customer, null: false
      t.integer :amount_pence, null: false
      t.string :reason
      t.timestamps
    end
  end
end
