class CreateSilasCompactions < ActiveRecord::Migration[8.1]
  def change
    create_table :silas_compactions do |t|
      t.references :session, null: false, index: false # covered by the unique composite below
      # Provenance only (never in a WHERE — see docs/conventions.md on indexes):
      # the turn whose index is up_to_turn_index, kept so an operator can walk
      # from a summary back to the rows it replaced.
      t.references :up_to_turn, null: false, index: false
      # THE query + claim column: a compaction covers session turns
      # 0..up_to_turn_index inclusive.
      t.integer :up_to_turn_index, null: false
      t.string :status, null: false, default: "pending" # pending | completed
      t.text :summary
      t.integer :tokens_before   # the measured context size that triggered this
      t.integer :input_tokens    # what the summarisation call itself cost
      t.integer :output_tokens
      t.string :model            # which model wrote the summary
      t.timestamps
    end

    # The compare-and-swap claim: only one execution may create the compaction
    # for a given span, however many racing replays attempt it. Also serves the
    # read path (latest completed compaction per session).
    add_index :silas_compactions, [ :session_id, :up_to_turn_index ], unique: true
  end
end
