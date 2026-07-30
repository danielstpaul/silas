require "rails_helper"

# The mounted MCP endpoint: a remote tools/call runs through the Ledger with
# the same exactly-once and effect-mode semantics as the in-process loop —
# and a gated call PARKS instead of erroring. The park is rows, so it holds
# for days, across client disconnects, worker restarts and deploys, and the
# silas_await_decision tool polls it to settlement.
RSpec.describe "the mounted MCP endpoint", type: :request do
  include ActiveJob::TestHelper

  def recording_tool(approval: :never)
    executions = []
    tool = Object.new
    tool.define_singleton_method(:executions) { executions }
    tool.define_singleton_method(:effect_mode) { :at_most_once }
    tool.define_singleton_method(:approval_policy) { approval }
    tool.define_singleton_method(:call) { |**args| executions << args; { "ok" => true, "echo" => args } }
    tool
  end

  def configure!(tool, approval: :never)
    Silas.configure do |c|
      c.mcp_auth = ->(_controller) { } # pass = do not render
      c.tool_resolver = ->(_name) { tool }
      c.tool_definitions = -> { [ { "name" => "record", "description" => "records", "input_schema" => { "type" => "object", "properties" => {}, "required" => [] } } ] }
    end
  end

  def rpc(method, params = nil, id: 1)
    post "/silas/mcp",
         params: { jsonrpc: "2.0", id: id, method: method, params: params }.compact.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    JSON.parse(response.body) if response.body.present?
  end

  def call_tool(name, arguments = {})
    rpc("tools/call", { name: name, arguments: arguments })
  end

  def payload_of(rpc_response)
    JSON.parse(rpc_response.dig("result", "content", 0, "text"))
  end

  it "denies everything by default" do
    post "/silas/mcp", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:not_found)
  end

  it "speaks the protocol: initialize and tools/list, with the await tool advertised" do
    configure!(recording_tool)

    expect(rpc("initialize", { protocolVersion: "2025-06-18" }).dig("result", "serverInfo", "name")).to eq("silas")

    names = rpc("tools/list").dig("result", "tools").map { |t| t["name"] }
    expect(names).to include("record", "silas_await_decision")
  end

  it "executes an ungated call through the Ledger, exactly once, on an mcp-channel session" do
    tool = recording_tool
    configure!(tool)

    result = payload_of(call_tool("record", { "note" => "hi" }))

    expect(result).to eq({ "ok" => true, "echo" => { "note" => "hi" } })
    expect(tool.executions).to eq([ { note: "hi" } ])

    invocation = Silas::ToolInvocation.sole
    expect(invocation).to have_attributes(status: "completed", tool_name: "record")
    expect(invocation.turn.session.channel).to eq("mcp")
    expect(invocation.turn.reload.status).to eq("completed")
  end

  it "tolerates the legacy mcp__silas__ name prefix" do
    tool = recording_tool
    configure!(tool)

    payload_of(call_tool("mcp__silas__record"))
    expect(Silas::ToolInvocation.sole.tool_name).to eq("record")
  end

  describe "a gated call" do
    it "parks instead of erroring, and names the invocation and the await tool" do
      tool = recording_tool(approval: :always)
      configure!(tool)

      parked = payload_of(call_tool("record", { "amount" => 500 }))

      expect(parked["status"]).to eq("awaiting_approval")
      expect(parked["expires_at"]).to be_present
      expect(parked.dig("await_with", "tool")).to eq("silas_await_decision")
      expect(tool.executions).to be_empty

      invocation = Silas::ToolInvocation.find(parked["invocation_id"])
      expect(invocation.approval_state).to eq("required")
      expect(invocation.turn.reload.status).to eq("waiting")
    end

    it "await returns still-waiting immediately when nobody has decided" do
      tool = recording_tool(approval: :always)
      configure!(tool)
      parked = payload_of(call_tool("record"))

      again = payload_of(call_tool("silas_await_decision",
                                   { "invocation_id" => parked["invocation_id"], "wait_seconds" => 0 }))
      expect(again["status"]).to eq("awaiting_approval")
      expect(tool.executions).to be_empty
    end

    it "await executes exactly once after a human approves — the whole point" do
      tool = recording_tool(approval: :always)
      configure!(tool)
      parked = payload_of(call_tool("record", { "amount" => 500 }))
      invocation = Silas::ToolInvocation.find(parked["invocation_id"])

      invocation.approve!(by: "dana@example.com")

      settled = payload_of(call_tool("silas_await_decision",
                                     { "invocation_id" => invocation.id, "wait_seconds" => 5 }))

      expect(settled["status"]).to eq("completed")
      expect(settled["decided_by"]).to eq("dana@example.com")
      expect(settled["result"]).to eq({ "ok" => true, "echo" => { "amount" => 500 } })
      expect(tool.executions.size).to eq(1)
      expect(invocation.reload.turn.status).to eq("completed")
    end

    it "await reports a decline as the decision it is, not an error" do
      tool = recording_tool(approval: :always)
      configure!(tool)
      parked = payload_of(call_tool("record"))
      invocation = Silas::ToolInvocation.find(parked["invocation_id"])

      invocation.decline!(reason: "not today", by: "dana@example.com")

      settled = payload_of(call_tool("silas_await_decision", { "invocation_id" => invocation.id }))
      expect(settled["status"]).to eq("failed")
      expect(settled["result"]).to eq({ "denied" => "not today" })
      expect(tool.executions).to be_empty
    end

    it "await never re-enters a call that is executing right now" do
      tool = recording_tool(approval: :always)
      configure!(tool)
      parked = payload_of(call_tool("record"))
      invocation = Silas::ToolInvocation.find(parked["invocation_id"])

      # A worker is mid-execution: claimed pending -> started. Re-entering the
      # settle path here would misread a healthy run as a crash and park it
      # in doubt.
      invocation.update!(approval_state: "approved", status: "started")

      still = payload_of(call_tool("silas_await_decision",
                                   { "invocation_id" => invocation.id, "wait_seconds" => 0 }))
      expect(tool.executions).to be_empty
      expect(invocation.reload.status).to eq("started")
      expect(still["status"]).to eq("awaiting_approval") # not settled, not corrupted
    end
  end

  it "refuses to await an invocation that did not originate on the endpoint" do
    configure!(recording_tool)
    session = Silas::Session.create!
    turn = Silas::Turn.create!(session: session, index: 0, input: "x", status: "waiting")
    step = Silas::Step.create!(turn: turn, index: 0, status: "completed", terminal: false)
    foreign = Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t1",
                                            tool_name: "record", arguments: {},
                                            effect_mode: "at_most_once", approval_state: "required")

    result = call_tool("silas_await_decision", { "invocation_id" => foreign.id }).fetch("result")
    expect(result["isError"]).to be(true)
  end

  it "returns a named error for an unknown invocation id" do
    configure!(recording_tool)
    result = call_tool("silas_await_decision", { "invocation_id" => 999_999 }).fetch("result")
    expect(result["isError"]).to be(true)
    expect(result.dig("content", 0, "text")).to include("999999")
  end
end
