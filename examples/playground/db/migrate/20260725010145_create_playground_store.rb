class CreatePlaygroundStore < ActiveRecord::Migration[8.1]
  # A tiny store. The point of these tables is that they are ORDINARY app
  # tables — the agent's tools read and write them directly, and a refund is
  # a row in the same database as the Silas ledger. That co-location is the
  # whole reason `transactional!` can promise exactly-once.
  def change
    create_table :customers do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.timestamps
    end

    create_table :orders do |t|
      t.references :customer, null: false, foreign_key: true
      t.string :item, null: false
      t.integer :amount_pence, null: false
      t.string :status, null: false, default: "shipped"
      t.datetime :placed_at, null: false
      t.timestamps
    end

    create_table :refunds do |t|
      t.references :order, null: false, foreign_key: true
      t.integer :amount_pence, null: false
      t.string :reason
      t.timestamps
    end
  end
end
