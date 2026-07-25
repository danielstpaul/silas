require "rails_helper"

# Real-API smoke (excluded from the default run):
#   ANTHROPIC_API_KEY=... bundle exec rspec spec/smoke --tag smoke
RSpec.describe "real API smoke", :smoke do
  before do
    skip "ANTHROPIC_API_KEY not set" if ENV["ANTHROPIC_API_KEY"].blank?

    ::RubyLLM.configure { |c| c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] }
    Silas::Registry.install!(root: DummyApp.root)
    Silas.configure do |c|
      c.adapter = :ruby_llm
      c.default_model = "claude-haiku-4-5-20251001"
      c.isolate_steps = false
    end
  end

  it "runs a real turn end-to-end with an intercepted tool call" do
    session = Silas::Session.create!
    turn = Silas::Turn.create!(
      session: session, index: 0,
      input: "Use the echo_note tool with text 'hello from silas', then reply with exactly: done"
    )

    Silas::AgentLoopJob.perform_now(turn.id)

    turn.reload
    expect(turn.status).to eq("completed")
    expect(turn.steps.count).to be >= 2

    invocation = turn.tool_invocations.find_by(tool_name: "echo_note")
    expect(invocation.status).to eq("completed")
    expect(invocation.result).to eq({ "echo" => "hello from silas" })

    final_text = turn.steps.order(:index).last.response_blocks
                     .select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    expect(final_text.downcase).to include("done")
  end
end
