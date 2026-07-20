class Agents::Scribe::Tools::SignScroll < Silas::Tool
  description "Sign a scroll."
  transactional!

  def call(scroll:)
    { "signed" => scroll }
  end
end
