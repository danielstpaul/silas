require "rails_helper"
require "tmpdir"

RSpec.describe "connections" do
  include ActiveJob::TestHelper

  # A fake MCP client so no network is touched.
  def fake_client(calls:)
    client = Object.new
    client.define_singleton_method(:list_tools) do
      [ { "name" => "search_issues", "description" => "Search Linear issues",
          "inputSchema" => { "type" => "object", "properties" => { "query" => { "type" => "string" } } } } ]
    end
    client.define_singleton_method(:call_tool) do |name, args|
      calls << [ name, args ]
      { "content" => [ { "type" => "text", "text" => "found 2 issues for #{args['query']}" } ] }
    end
    client
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      conn = @root.join("app/agent/connections")
      conn.mkpath
      conn.join("linear.yml").write(<<~YAML)
        transport: http
        url: https://mcp.example.test/mcp
        approval: never
        effect: at_most_once
      YAML
      @calls = []
      Silas.configure { |c| c.mcp_client_factory = ->(_conn) { fake_client(calls: @calls) } }
      example.run
    end
  end

  it "surfaces remote tools namespaced, in the definitions and the digest" do
    reg = Silas::Registry.new(root: @root)
    names = reg.definitions.map { |d| d["name"] }
    expect(names).to include("linear__search_issues")
    # same digest across instances (stable), and it includes the remote tool
    expect(reg.digest).to eq(Silas::Registry.new(root: @root).digest)
  end

  it "resolves a remote tool to a RemoteTool that calls the MCP client" do
    reg = Silas::Registry.new(root: @root)
    tool = reg.resolver.call("linear__search_issues")
    expect(tool).to be_a(Silas::Connection::RemoteTool)
    expect(tool.approval_policy).to eq(:never)
    expect(tool.effect_mode).to eq(:at_most_once)
    result = tool.call(query: "bug")
    expect(result["content"].first["text"]).to include("found 2 issues for bug")
    expect(@calls).to eq([ [ "search_issues", { "query" => "bug" } ] ])
  end

  it "runs a full turn where the model calls the remote tool through the Ledger" do
    engine = FakeEngine.new do |context|
      if context[:index].zero?
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "searching" } ],
                             tool_calls: [ EngineScripts.tool_call("c0", "linear__search_issues", query: "outage") ])
      else
        EngineScripts.result(blocks: [ { "type" => "text", "text" => "Found the issues." } ])
      end
    end
    Silas.configure do |c|
      c.adapter = engine
      c.isolate_steps = false
      c.mcp_client_factory = ->(_conn) { fake_client(calls: @calls) }
    end
    Silas::Registry.install!(root: @root)

    session = Silas.agent.start(input: "search for the outage issues")
    Silas::AgentLoopJob.perform_now(session.turns.sole.id)

    turn = session.turns.sole.reload
    expect(turn.status).to eq("completed")
    inv = turn.tool_invocations.find_by(tool_name: "linear__search_issues")
    expect(inv.status).to eq("completed")
    expect(inv.result["content"].first["text"]).to include("found 2 issues for outage")
    expect(@calls).to eq([ [ "search_issues", { "query" => "outage" } ] ])
  end

  it "fails loud at boot when a connection is unreachable" do
    bad = @root.join("app/agent/connections/broken.yml")
    bad.write("transport: http\nurl: https://nope.test/mcp\n")
    Silas.configure { |c| c.mcp_client_factory = ->(_c) { raise "connection refused" } }
    expect { Silas::Connections.new(root: @root, client_factory: Silas.config.mcp_client_factory).warm! }
      .to raise_error(Silas::Error, /tools\/list failed at boot/)
  end
end
