# Agent evals: fixtures are scenarios, assertions run against the durable
# transcript. Run them as a deploy gate with `bin/rails silas:eval` (or bin/ci).
# You script the model's DECISIONS; the real Ledger runs your real tools.
Silas::Eval.scenario "example: the agent uses the example tool" do
  input "Please echo 'hello'."
  on_step 0, call: { name: "example_tool", arguments: { message: "hello" } }
  on_step 1, text: "Done — echoed 'hello'."

  expect do
    assert_tool_called "example_tool"
    assert_tool_arg    "example_tool", :message, "hello"
    assert_final_matches(/echoed/i)
    assert_turn_completed
  end
end

# Opt-in, offline-skippable LLM-graded check (runs against the real engine):
# Silas::Eval.scenario "tone is professional", tags: %i[rubric] do
#   mode :real
#   input "My order never arrived and I'm furious."
#   expect { assert_rubric "The reply is empathetic and promises no amount a tool didn't return." }
# end
