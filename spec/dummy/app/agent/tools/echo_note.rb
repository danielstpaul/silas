class Agent::Tools::EchoNote < Silas::Tool
  description "Echo a note back."
  transactional!

  def call(text:, loud: nil)
    { "echo" => loud ? text.upcase : text }
  end
end
