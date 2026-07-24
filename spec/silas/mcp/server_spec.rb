require "rails_helper"
require "net/http"

# Integration coverage for the raw-TCP MCP server: boot, readiness, token auth,
# and tools/call through the Ledger on a server thread. (Ported from the deleted
# :agent_sdk adapter spec — the server outlived the engine.)
RSpec.describe Silas::Mcp::Server do
  # The server handles requests on background threads with their own AR
  # connections, so the durable rows must be committed, not held in a test
  # transaction.
  self.use_transactional_tests = false

  after do
    [ Silas::ToolInvocation, Silas::Step, Silas::Turn, Silas::Session ].each(&:delete_all)
  end

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi", status: "running") }
  let(:step) { Silas::Step.create!(turn: turn, index: 0) }

  let(:tool) do
    t = Object.new
    t.define_singleton_method(:effect_mode) { :transactional }
    t.define_singleton_method(:approval_policy) { :never }
    t.define_singleton_method(:session=) { |s| @session = s }
    t.define_singleton_method(:call) { |**args| { "echo" => args[:text] } }
    t
  end

  let(:definitions) do
    [ { "name" => "echo_note", "description" => "Echo", "input_schema" => { "type" => "object" } } ]
  end

  def start_server
    described_class.start(turn: turn, step: step, tools: definitions, resolver: ->(_n) { tool })
      .tap(&:await_ready!)
  end

  def post(url, body)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri.request_uri, "content-type" => "application/json")
    req.body = body
    Net::HTTP.new(uri.host, uri.port).request(req)
  end

  def rpc(url, method, params = {}, id = 1)
    res = post(url, JSON.generate("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    [ res.code.to_i, res.body.to_s.empty? ? nil : JSON.parse(res.body) ]
  end

  it "boots on an ephemeral port, becomes ready, and serves the MCP handshake" do
    server = start_server
    status, body = rpc(server.mcp_url, "initialize", { "protocolVersion" => "2025-06-18" })
    expect(status).to eq(200)
    expect(body["result"]["serverInfo"]["name"]).to eq("silas")
    expect(server.port).to be > 0
  ensure
    server&.stop
  end

  it "rejects a bad ?t= token (403) and a wrong turn path (404)" do
    server = start_server
    base = "http://127.0.0.1:#{server.port}"
    good = URI(server.mcp_url)

    expect(rpc("#{base}#{good.path}?t=wrong", "tools/list").first).to eq(403)
    expect(rpc("#{base}/mcp/999999?#{good.query}", "tools/list").first).to eq(404)
  ensure
    server&.stop
  end

  it "rejects non-POST requests (405)" do
    server = start_server
    uri = URI(server.mcp_url)
    res = Net::HTTP.new(uri.host, uri.port).request(Net::HTTP::Get.new(uri.request_uri))
    expect(res.code.to_i).to eq(405)
  ensure
    server&.stop
  end

  it "executes tools/call through the Ledger on a server thread (own AR connection)" do
    server = start_server
    status, body = rpc(server.mcp_url, "tools/call",
                       { "name" => "mcp__silas__echo_note", "arguments" => { "text" => "hey" } }, 2)
    expect(status).to eq(200)
    expect(JSON.parse(body["result"]["content"].first["text"])).to eq("echo" => "hey")

    invocation = turn.tool_invocations.sole
    expect(invocation).to have_attributes(tool_name: "echo_note", status: "completed", step_id: step.id)
  ensure
    server&.stop
  end
end
