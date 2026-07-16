class CreateStore < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.string :customer, null: false
      t.string :item, null: false
      t.integer :amount_pence, null: false
      t.string :status, null: false, default: "delivered"
      t.timestamps
    end
    create_table :refunds do |t|
      t.references :order, null: false
      t.integer :amount_pence, null: false
      t.timestamps
    end
  end
end
