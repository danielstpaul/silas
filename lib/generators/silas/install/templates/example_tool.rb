# Tool identity is the filename: this is the "example_tool" tool.
# The keyword signature of #call IS the schema the model sees.
class Agent::Tools::ExampleTool < Silas::Tool
  description "Echo a message back (replace me with a real capability)."
  # approval :always                # park for human approval before running
  # transactional!                  # DB-only side effects -> exactly-once
  at_most_once!                     # default: external effects park when in doubt

  def call(message:)
    { echo: message }
  end
end
