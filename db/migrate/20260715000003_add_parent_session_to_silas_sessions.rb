class AddParentSessionToSilasSessions < ActiveRecord::Migration[8.1]
  def change
    # Subagent lineage (observability only, not correctness-load-bearing): a
    # delegated session records the parent that spawned it.
    add_column :silas_sessions, :parent_session_id, :bigint
    add_index :silas_sessions, :parent_session_id
  end
end
