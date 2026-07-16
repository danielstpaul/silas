require "rails_helper"

# Real `claude -p` smoke (the gem analog of the Phase-0 claude_p spike):
#   ANTHROPIC_API_KEY=... bundle exec rspec spec/smoke --tag smoke
# Skips unless the key, the CLI, and a supported version are all present.
RSpec.describe "the :agent_sdk adapter against real claude -p", :smoke do
  self.use_transactional_tests = false

  before do
    skip "ANTHROPIC_API_KEY not set" if ENV["ANTHROPIC_API_KEY"].blank?
    skip "claude CLI not on PATH" if `which claude`.strip.empty?
    begin
      Silas::AgentSdk::VersionGuard.assert!("claude")
    rescue Silas::Error => e
      skip e.message
    end

    Silas::Registry.install!(root: DummyApp.root)
    Silas.configure do |c|
      c.engine = :agent_sdk
      c.agent_sdk_model = "claude-haiku-4-5-20251001"
      c.isolate_steps = false
    end
    Silas::Registry.install!(root: DummyApp.root)
  end

  after do
    [ Silas::ToolInvocation, Silas::Step, Silas::Turn, Silas::Session ].each(&:delete_all)
  end

  it "runs a real turn, executing echo_note through the hosted MCP + Ledger" do
    session = Silas.agent.start(
      input: "Use the echo_note tool with text 'hello from silas', then reply with exactly: done"
    )
    turn = session.turns.sole

    Silas::AgentLoopJob.perform_now(turn.id)

    turn.reload
    expect(turn.status).to eq("completed")
    expect(turn.cli_session_id).to be_present

    invocation = turn.tool_invocations.find_by(tool_name: "echo_note")
    expect(invocation).to be_present
    expect(invocation.status).to eq("completed")
    expect(invocation.result).to eq("echo" => "hello from silas")

    anchor = turn.steps.find_by(index: 0)
    final = Array(anchor.response_blocks).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    expect(final.downcase).to include("done")
  end
end
