# The observable side effect: one row per ACTUAL execution, unique nonce, no
# unique constraint — duplicates must be countable, not prevented (the gem's
# ledger is what's under test).
class Agent::Tools::RecordRow < Silas::Tool
  description "Record a row."
  transactional!

  def call(i:, c:)
    SideEffectRow.create!(session_id: session.id, key: "t#{i}_c#{c}", nonce: SecureRandom.uuid)
    { "recorded" => "t#{i}_c#{c}" }
  end
end
