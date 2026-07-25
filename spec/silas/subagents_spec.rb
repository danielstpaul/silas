require "rails_helper"

RSpec.describe "subagents" do
  include ActiveJob::TestHelper

  before { Silas::Registry.install!(root: DummyApp.root) }

  describe "discovery + isolation" do
    it "advertises the subagent roster and adds delegate to the root toolset" do
      expect(Silas.subagent_index).to eq([ [ "researcher", "Researches a question and returns a concise summary." ] ])
      expect(Silas.tool_definitions.map { |d| d["name"] }).to include("delegate")
      expect(Silas.subagent?("researcher")).to be(true)
      expect(Silas.subagent?("nobody")).to be(false)
    end

    it "gives a subagent ONLY its own tools (not the root's, and no delegate)" do
      scope = Silas.subagent_scope("researcher")
      names = scope.definitions.map { |d| d["name"] }
      expect(names).to include("note")
      expect(names).not_to include("echo_note", "refund_order", "delegate")
    end

    it "requires a description in the subagent's agent.yml" do
      Dir.mktmpdir do |dir|
        sub = Pathname(dir).join("app/agent/subagents/x")
        sub.join("tools").mkpath
        sub.join("agent.yml").write("limits:\n  max_steps: 3\n")
        sub.join("instructions.md").write("hi")
        expect { Silas::Registry.new(root: Pathname(dir)).subagent_scopes }
          .to raise_error(Silas::Error, /must set `description`/)
      end
    end
  end

  describe "delegation (durable, exactly-once)" do
    # The root engine emits a delegate call on step 0; the subagent's engine
    # (swapped in during the nested run) records a note and answers.
    def script_engine
      FakeEngine.new do |context|
        agent = Silas.agent
        if agent.description.include?("Researches") # nested subagent context
          if context[:index].zero?
            EngineScripts.result(blocks: [ { "type" => "text", "text" => "researching" } ],
                                 tool_calls: [ EngineScripts.tool_call("n0", "note", text: "found it") ])
          else
            EngineScripts.result(blocks: [ { "type" => "text", "text" => "The answer is 42." } ])
          end
        elsif context[:index].zero? # root: delegate
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "delegating" } ],
                               tool_calls: [ EngineScripts.tool_call("d0", "delegate", subagent: "researcher", input: "what is the answer?") ])
        else # root: final
          EngineScripts.result(blocks: [ { "type" => "text", "text" => "My researcher says: The answer is 42." } ])
        end
      end
    end

    before do
      Silas.configure { |c| c.adapter = script_engine; c.isolate_steps = false }
      Silas::Registry.install!(root: DummyApp.root)
    end

    it "runs the subagent in a fresh nested session and returns its answer to the parent" do
      session = Silas.agent.start(input: "answer my question via research")
      turn = session.turns.sole
      Silas::AgentLoopJob.perform_now(turn.id)

      turn.reload
      expect(turn.status).to eq("completed")

      delegate = turn.tool_invocations.find_by(tool_name: "delegate")
      expect(delegate.status).to eq("completed")
      expect(delegate.result["answer"]).to eq("The answer is 42.")

      nested = Silas::Session.find(delegate.result["session_id"])
      expect(nested).to have_attributes(agent_name: "researcher", parent_session_id: session.id)
      expect(nested.turns.sole.status).to eq("completed")
      # The subagent's own tool ran exactly once, in the nested session.
      note = nested.turns.sole.tool_invocations.find_by(tool_name: "note")
      expect(note.status).to eq("completed")
      expect(note.result).to eq("noted" => "found it")
    end

    it "restores the root scope after delegation (parent keeps its own tools)" do
      session = Silas.agent.start(input: "delegate then continue")
      Silas::AgentLoopJob.perform_now(session.turns.sole.id)
      # After the nested run, the root resolver is back — delegate/echo_note resolve.
      expect(Silas.tool_definitions.map { |d| d["name"] }).to include("delegate", "echo_note")
      expect(Silas.agent.description).not_to include("Researches")
    end

    it "returns an error result for an unknown subagent (no crash)" do
      tool = Silas::Tools::Delegate.new
      tool.session = Silas::Session.create!
      expect(tool.call(subagent: "ghost", input: "x")).to eq("error" => 'unknown subagent "ghost"')
    end
  end
end
