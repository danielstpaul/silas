class AddDefinitionsSnapshotToSilasTurns < ActiveRecord::Migration[8.1]
  def change
    # The model-visible definitions at turn start — {"tools" => [schemas...],
    # "final_answer" => schema-or-nil} — stamped once beside
    # instructions_snapshot. A parked turn resumes AGAINST this snapshot, so a
    # deploy that changes tools no longer fails parked work; the digest guard
    # remains the contract for pre-snapshot rows (NULL here).
    add_column :silas_turns, :definitions_snapshot, :json
  end
end
