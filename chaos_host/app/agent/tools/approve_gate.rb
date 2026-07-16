class Agent::Tools::ApproveGate < Silas::Tool
  description "A gated action (parks for approval)."
  approval :always
  transactional!

  def call(i:)
    SideEffectRow.create!(session_id: session.id, key: "gate_#{i}", nonce: SecureRandom.uuid)
    { "approved_action" => i }
  end
end
