class Agent::Subagents::Researcher::Tools::Note < Silas::Tool
  description "Record a research note."
  transactional!

  def call(text:)
    { "noted" => text }
  end
end
