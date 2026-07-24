require "rails_helper"

RSpec.describe Silas::Mcp::Handler do
  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi", status: "running") }
  let(:step) { Silas::Step.create!(turn: turn, index: 0) }
  let(:token) { "secret-token" }

  let(:tool) do
    executions = []
    t = Object.new
    t.define_singleton_method(:executions) { executions }
    t.define_singleton_method(:effect_mode) { :transactional }
    t.define_singleton_method(:approval_policy) { :never }
    t.define_singleton_method(:session=) { |s| @session = s }
    t.define_singleton_method(:session) { @session }
    t.define_singleton_method(:call) { |**args| executions << args; { "echo" => args[:text] } }
    t
  end

  let(:definitions) do
    [ { "name" => "echo_note", "description" => "Echo", "input_schema" => { "type" => "object" } } ]
  end

  subject(:handler) do
    described_class.new(turn: turn, step: step, tools: definitions,
                        resolver: ->(_name) { tool }, token: token)
  end

  def call(method, params = {}, id = 1, path: "/mcp/#{turn.id}", query_token: token)
    body = JSON.generate("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)
    status, payload = handler.call(path: path, query_token: query_token, body: body)
    [ status, payload && JSON.parse(payload) ]
  end

  it "rejects a wrong turn path (404) and a bad token (403)" do
    expect(call("tools/list", {}, 1, path: "/mcp/999999").first).to eq(404)
    expect(call("tools/list", {}, 1, query_token: "nope").first).to eq(403)
  end

  it "handles initialize and returns server info" do
    status, body = call("initialize", { "protocolVersion" => "2025-06-18" })
    expect(status).to eq(200)
    expect(body["result"]["serverInfo"]["name"]).to eq("silas")
    expect(body["result"]["protocolVersion"]).to eq("2025-06-18")
  end

  it "returns 202 with no body for notifications/initialized" do
    expect(call("notifications/initialized")).to eq([ 202, nil ])
  end

  it "lists tools in MCP shape (inputSchema)" do
    _, body = call("tools/list")
    expect(body["result"]["tools"].first).to include("name" => "echo_note", "inputSchema" => { "type" => "object" })
  end

  it "runs tools/call through the Ledger exactly once and echoes the result" do
    status, body = call("tools/call",
                        { "name" => "mcp__silas__echo_note", "arguments" => { "text" => "hey" } }, 2)
    expect(status).to eq(200)

    invocation = turn.tool_invocations.sole
    expect(invocation).to have_attributes(tool_name: "echo_note", status: "completed", step_id: step.id)
    expect(invocation.result).to eq("echo" => "hey")
    expect(tool.executions).to eq([ { text: "hey" } ]) # exactly once
    expect(tool.session).to eq(session)                # ledger set tool context

    content = JSON.parse(body["result"]["content"].first["text"])
    expect(content).to eq("echo" => "hey")
  end

  it "returns a JSON-RPC error for an unknown method" do
    _, body = call("nonsense/method")
    expect(body["error"]["code"]).to eq(-32601)
  end
end
