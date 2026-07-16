class CreateSilasTables < ActiveRecord::Migration[8.1]
  def change
    create_table :silas_sessions do |t|
      t.string :agent_name, null: false, default: "agent"
      t.string :status, null: false, default: "active" # active | archived
      t.string :continuation_token
      t.string :channel                                # channels seam (v-next)
      # json (not jsonb): must work on SQLite and Postgres alike.
      t.json :metadata, null: false, default: {}
      t.json :loaded_skills, null: false, default: []
      t.timestamps
    end
    add_index :silas_sessions, :continuation_token, unique: true

    create_table :silas_turns do |t|
      t.references :session, null: false, index: true
      t.integer :index, null: false
      t.string :status, null: false, default: "queued"
      # queued | running | waiting (parked) | in_doubt | completed | failed | canceled
      t.text :input, null: false
      t.text :instructions_snapshot   # rendered ONCE at :prepare; immutable after set
      t.string :definitions_digest    # tool schemas + skill descriptions at turn start
      t.string :failure_reason
      t.string :job_id
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.integer :cost_microcents, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :silas_turns, [ :session_id, :index ], unique: true
    # Single-active-turn invariant: at most one non-final turn per session.
    add_index :silas_turns, :session_id, unique: true,
              where: "status IN ('queued','running','waiting','in_doubt')",
              name: "index_silas_turns_single_active"

    create_table :silas_steps do |t|
      t.references :turn, null: false, index: true
      t.integer :index, null: false
      t.string :status, null: false, default: "started" # started | completed
      t.string :model
      t.json :response_blocks
      t.string :stop_reason
      # Write-once after completion; THE loop-control column. Resumed
      # continuations must re-derive the identical step sequence from it.
      t.boolean :terminal
      t.integer :input_tokens
      t.integer :output_tokens
      t.timestamps
    end
    # At most one persisted model response per (turn, index).
    add_index :silas_steps, [ :turn_id, :index ], unique: true

    create_table :silas_tool_invocations do |t|
      t.references :step, null: false, index: true
      t.references :turn, null: false # denormalized: :once approval queries + rescue sweeps
      t.string :tool_call_id, null: false
      t.string :tool_name, null: false
      t.json :arguments, null: false, default: {}
      t.string :status, null: false, default: "pending"
      # pending | started | completed | failed | in_doubt
      # Snapshotted from the tool class at creation, so editing a tool mid-park
      # cannot change execution or in-doubt semantics for an existing invocation.
      t.string :effect_mode, null: false # transactional | at_most_once | idempotent
      t.json :result
      t.text :error
      t.string :approval_state # NULL | required | approved | declined | expired
      t.datetime :approval_expires_at
      t.string :approved_by
      t.text :decline_reason
      t.timestamps
    end
    # THE exactly-once key (existence checks are an optimization).
    add_index :silas_tool_invocations, [ :step_id, :tool_call_id ], unique: true
    add_index :silas_tool_invocations, [ :turn_id, :status ]
  end
end
