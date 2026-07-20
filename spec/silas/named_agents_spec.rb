require "rails_helper"

# Named top-level agents (app/agents/<name>/ — the staff pattern): discovery,
# per-agent scope isolation, session attribution, loop + resume under the
# right scope, and the thread-safety of scope switching.
RSpec.describe "named agents" do
  before { Silas::Registry.install!(root: DummyApp.root) }

  it "discovers app/agents/* as named scopes" do
    expect(Silas.named_agent_scopes.keys).to eq(%w[filer scribe])
  end

  it "builds isolated scopes — one agent's tools are invisible to the other" do
    scribe = Silas.named_agent_scopes["scribe"]
    filer  = Silas.named_agent_scopes["filer"]
    expect(scribe.definitions.map { |d| d["name"] }).to include("sign_scroll", "load_skill")
    expect(scribe.definitions.map { |d| d["name"] }).not_to include("file_report")
    expect(filer.definitions.map { |d| d["name"] }).to eq(%w[file_report])
    expect(scribe.digest).not_to eq(filer.digest)
  end

  it "Silas.agent(:name) returns a handle with the agent.yml definition" do
    handle = Silas.agent(:scribe)
    expect(handle.description).to eq("The Scribe — signs scrolls.")
    expect(handle.max_steps).to eq(7)
  end

  it "raises helpfully for unknown agents" do
    expect { Silas.agent(:butler) }
      .to raise_error(Silas::Error, /unknown agent :butler.*known: filer, scribe/)
  end

  it "runs a named agent's turn under its own scope, attributed on the session" do
    contexts = []
    engine = FakeEngine.new do |context|
      contexts << { system: context[:system], tools: context[:tools].map { |d| d["name"] } }
      if context[:index].zero?
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "signing" } ],
                             tool_calls: [ EngineScripts.tool_call("t0", "sign_scroll", scroll: "the fox charter") ])
      else
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "signed" } ])
      end
    end
    Silas.configure { |c| c.engine = engine; c.isolate_steps = false }
    Silas::Registry.install!(root: DummyApp.root)

    session = Silas.agent(:scribe).start(input: "sign the fox charter")
    expect(session.agent_name).to eq("scribe")
    Silas::AgentLoopJob.perform_now(session.turns.first.id)

    turn = session.turns.first.reload
    expect(turn.status).to eq("completed")
    expect(contexts.first[:system]).to include("You are the Scribe")
    expect(contexts.first[:tools]).to include("sign_scroll")
    expect(contexts.first[:tools]).not_to include("file_report", "echo_note")
    expect(turn.definitions_digest).to eq(Silas.named_agent_scopes["scribe"].digest)
    inv = turn.tool_invocations.sole
    expect(inv.tool_name).to eq("sign_scroll")
    expect(inv.result).to eq({ "signed" => "the fox charter" })
  end

  it "a resumed turn re-establishes the named scope (no root-tools wake-up)" do
    engine = FakeEngine.new do |context|
      EngineScripts.result(blocks: [ { "type" => "text", "text" => "done" } ])
    end
    Silas.configure { |c| c.engine = engine; c.isolate_steps = false }
    Silas::Registry.install!(root: DummyApp.root)

    session = Silas.agent(:filer).start(input: "hello")
    turn = session.turns.first
    Silas::AgentLoopJob.perform_now(turn.id)
    expect(turn.reload.status).to eq("completed")

    # A second perform on the SAME turn (rescuer double-fire / crash resume
    # path) must resolve the filer scope again without error — and stays a
    # no-op because the turn is terminal.
    expect { Silas::AgentLoopJob.perform_now(turn.id) }.not_to raise_error
  end

  it "fails loud when a session's agent directory no longer exists" do
    session = Silas::Session.create!(agent_name: "ghost")
    turn = session.turns.create!(index: 0, input: "hi")
    expect { Silas::AgentLoopJob.perform_now(turn.id) }
      .to raise_error(Silas::Error, /no app\/agents\/ghost/)
  end

  it "scope switching is isolated across threads" do
    scribe = Silas.named_agent_scopes["scribe"]
    filer  = Silas.named_agent_scopes["filer"]
    seen = Queue.new
    barrier = Queue.new

    t1 = Thread.new do
      Silas.with_agent_scope(scribe) do
        barrier.pop # wait until t2 has set ITS scope
        seen << [ :t1, Silas.tool_definitions.map { |d| d["name"] } ]
      end
    end
    t2 = Thread.new do
      Silas.with_agent_scope(filer) do
        barrier << true
        seen << [ :t2, Silas.tool_definitions.map { |d| d["name"] } ]
      end
    end
    [ t1, t2 ].each(&:join)

    results = 2.times.map { seen.pop }.to_h
    expect(results[:t1]).to include("sign_scroll")
    expect(results[:t1]).not_to include("file_report")
    expect(results[:t2]).to eq(%w[file_report])
  end

  it "nested scopes restore the outer scope on exit" do
    scribe = Silas.named_agent_scopes["scribe"]
    filer  = Silas.named_agent_scopes["filer"]
    Silas.with_agent_scope(scribe) do
      Silas.with_agent_scope(filer) do
        expect(Silas.agent.description).to eq("") # filer has no description
      end
      expect(Silas.agent.description).to eq("The Scribe — signs scrolls.")
    end
    expect(Silas.current_scope).to be_nil
  end
end
