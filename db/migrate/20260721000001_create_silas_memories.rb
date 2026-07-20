class CreateSilasMemories < ActiveRecord::Migration[8.1]
  def change
    # Agent memory: entity-attributed facts with provenance and supersession
    # (graph-SHAPED — triples, no edges until the need is proven). Domain
    # memory belongs in YOUR tables; this is only for the fuzzy residue that
    # has no natural home ("author X prefers CSV", "reports arrive on the 15th").
    create_table :silas_memories do |t|
      t.string :agent_name, null: false            # whose memory ("agent" = root)
      t.string :scope, null: false, default: "agent" # agent (private) | app (shared)
      t.string :subject, null: false               # entity ref, e.g. "author:jane"
      t.string :attribute_name                     # optional: triple form
      t.text :content, null: false                 # the fact, plain prose
      t.string :status, null: false, default: "active" # active | superseded
      t.bigint :superseded_by_id
      t.bigint :session_id                         # provenance
      t.bigint :turn_id
      t.timestamps
    end
    add_index :silas_memories, [ :agent_name, :scope, :status ]
    add_index :silas_memories, [ :subject, :status ]
  end
end
