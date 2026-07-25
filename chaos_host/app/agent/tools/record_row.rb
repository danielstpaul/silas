# The observable side effect: one row per ACTUAL execution, unique nonce, no
# unique constraint — duplicates must be countable, not prevented (the gem's
# ledger is what's under test).
class Agent::Tools::RecordRow < Silas::Tool
  description "Record a row."
  transactional!

  # `turn:` keys the effect per turn — compact mode runs multi-turn sessions,
  # and without it turn 1's rows collide with turn 0's identical (i, c) pairs
  # and read as duplicates that never happened.
  def call(i:, c:, turn: 0)
    key = "u#{turn}_t#{i}_c#{c}"
    SideEffectRow.create!(session_id: session.id, key: key, nonce: SecureRandom.uuid)
    { "recorded" => key }
  end
end
