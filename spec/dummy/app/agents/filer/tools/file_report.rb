class Agents::Filer::Tools::FileReport < Silas::Tool
  description "File a report."
  at_most_once!

  def call(title:)
    { "filed" => title }
  end
end
