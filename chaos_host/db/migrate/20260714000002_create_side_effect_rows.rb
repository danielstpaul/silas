class CreateSideEffectRows < ActiveRecord::Migration[8.1]
  def change
    create_table :side_effect_rows do |t|
      t.bigint :session_id, null: false
      t.string :key, null: false
      t.string :nonce, null: false
      t.timestamps
    end
    add_index :side_effect_rows, [ :session_id, :key ] # NOT unique — duplicates countable
  end
end
