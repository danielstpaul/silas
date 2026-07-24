# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_24_223056) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "side_effect_rows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "nonce", null: false
    t.bigint "session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id", "key"], name: "index_side_effect_rows_on_session_id_and_key"
  end

  create_table "silas_memories", force: :cascade do |t|
    t.string "agent_name", null: false
    t.string "attribute_name"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "scope", default: "agent", null: false
    t.bigint "session_id"
    t.string "status", default: "active", null: false
    t.string "subject", null: false
    t.bigint "superseded_by_id"
    t.bigint "turn_id"
    t.datetime "updated_at", null: false
    t.index ["agent_name", "scope", "status"], name: "index_silas_memories_on_agent_name_and_scope_and_status"
    t.index ["subject", "status"], name: "index_silas_memories_on_subject_and_status"
  end

  create_table "silas_sessions", force: :cascade do |t|
    t.string "agent_name", default: "agent", null: false
    t.string "channel"
    t.string "continuation_token"
    t.datetime "created_at", null: false
    t.json "loaded_skills", default: [], null: false
    t.json "metadata", default: {}, null: false
    t.bigint "parent_session_id"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["continuation_token"], name: "index_silas_sessions_on_continuation_token", unique: true
    t.index ["parent_session_id"], name: "index_silas_sessions_on_parent_session_id"
  end

  create_table "silas_steps", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "index", null: false
    t.integer "input_tokens"
    t.string "model"
    t.integer "output_tokens"
    t.json "response_blocks"
    t.string "status", default: "started", null: false
    t.string "stop_reason"
    t.boolean "terminal"
    t.integer "turn_id", null: false
    t.datetime "updated_at", null: false
    t.index ["turn_id", "index"], name: "index_silas_steps_on_turn_id_and_index", unique: true
    t.index ["turn_id"], name: "index_silas_steps_on_turn_id"
  end

  create_table "silas_tool_invocations", force: :cascade do |t|
    t.datetime "approval_expires_at"
    t.string "approval_state"
    t.string "approved_by"
    t.json "arguments", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "decline_reason"
    t.string "effect_mode", null: false
    t.text "error"
    t.datetime "notified_at"
    t.json "result"
    t.string "status", default: "pending", null: false
    t.integer "step_id", null: false
    t.string "tool_call_id", null: false
    t.string "tool_name", null: false
    t.integer "turn_id", null: false
    t.datetime "updated_at", null: false
    t.index ["step_id", "tool_call_id"], name: "index_silas_tool_invocations_on_step_id_and_tool_call_id", unique: true
    t.index ["step_id"], name: "index_silas_tool_invocations_on_step_id"
    t.index ["turn_id", "status"], name: "index_silas_tool_invocations_on_turn_id_and_status"
    t.index ["turn_id"], name: "index_silas_tool_invocations_on_turn_id"
  end

  create_table "silas_turns", force: :cascade do |t|
    t.datetime "answered_at"
    t.json "budget_overrides", default: {}, null: false
    t.datetime "cancel_requested_at"
    t.integer "cost_microcents", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "definitions_digest"
    t.string "failure_reason"
    t.datetime "finished_at"
    t.integer "index", null: false
    t.text "input", null: false
    t.integer "input_tokens", default: 0, null: false
    t.text "instructions_snapshot"
    t.string "job_id"
    t.integer "output_tokens", default: 0, null: false
    t.integer "session_id", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id", "index"], name: "index_silas_turns_on_session_id_and_index", unique: true
    t.index ["session_id"], name: "index_silas_turns_on_session_id"
    t.index ["session_id"], name: "index_silas_turns_single_active", unique: true, where: "((status)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying, 'waiting'::character varying, 'in_doubt'::character varying])::text[]))"
  end
end
