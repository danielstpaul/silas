require "rails_helper"

RSpec.describe "the JSON API", type: :request do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create!(agent_name: "refunds") }
  let!(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund order 42", status: "waiting") }
  let!(:step) do
    Silas::Step.create!(turn: turn, index: 0, status: "completed", terminal: false,
                        response_blocks: [ { "type" => "text", "text" => "checking" } ])
  end
  let!(:invocation) do
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "issue_refund",
                                  effect_mode: "at_most_once", arguments: { "amount" => 120 },
                                  approval_state: "required")
  end

  def allow_api!
    Silas.configure { |c| c.api_auth = ->(_controller) { } } # pass = do not render
  end

  def json = JSON.parse(response.body)

  describe "deny-by-default auth" do
    it "404s every route when nothing is configured" do
      post "/silas/api/v1/sessions", params: { input: "hi" }
      expect(response).to have_http_status(:not_found)
      get "/silas/api/v1/sessions/#{session.id}"
      expect(response).to have_http_status(:not_found)
      post "/silas/api/v1/approvals/#{invocation.id}/approve"
      expect(response).to have_http_status(:not_found)
    end

    it "passes the controller to the host lambda" do
      seen = nil
      Silas.configure { |c| c.api_auth = ->(controller) { seen = controller } }
      get "/silas/api/v1/sessions/#{session.id}"
      expect(seen).to be_a(Silas::Api::V1::SessionsController)
    end
  end

  describe "sessions" do
    before { allow_api! }

    it "creates a session (channel nil — no outbound delivery jobs) with the queued turn" do
      expect {
        post "/silas/api/v1/sessions", params: { input: "hello", metadata: { ticket: "T-1" } }
      }.to change(Silas::Session, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(json["channel"]).to be_nil
      expect(json["turns"].size).to eq(1)
      expect(Silas::Session.find(json["id"]).metadata).to eq("ticket" => "T-1")
    end

    it "422s blank input and unknown agents" do
      post "/silas/api/v1/sessions", params: { input: "   " }
      expect(response).to have_http_status(:unprocessable_entity)

      post "/silas/api/v1/sessions", params: { input: "hi", agent: "nonexistent" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to match(/unknown agent/)
    end

    it "shows a session; ?trace=1 adds steps + invocations" do
      get "/silas/api/v1/sessions/#{session.id}"
      expect(json["turns"].first).not_to have_key("steps")
      expect(json["cost"]).to include("input_tokens")

      get "/silas/api/v1/sessions/#{session.id}", params: { trace: 1 }
      trace_steps = json["turns"].first["steps"]
      expect(trace_steps.first["text"]).to eq("checking")
      expect(trace_steps.first["invocations"].first["tool_name"]).to eq("issue_refund")
    end

    it "404s an unknown session as JSON, not HTML" do
      get "/silas/api/v1/sessions/999999"
      expect(response).to have_http_status(:not_found)
      expect(json["error"]).to eq("not found")
    end
  end

  describe "turns" do
    before { allow_api! }

    it "409s while a turn is active; creates once settled" do
      post "/silas/api/v1/sessions/#{session.id}/turns", params: { input: "more" }
      expect(response).to have_http_status(:conflict)

      turn.finish!(:completed)
      post "/silas/api/v1/sessions/#{session.id}/turns", params: { input: "more" }
      expect(response).to have_http_status(:created)
      expect(json["index"]).to eq(1)
    end

    it "cancels a parked turn immediately and says so" do
      post "/silas/api/v1/turns/#{turn.id}/cancel"
      expect(json["cancel"]).to eq("canceled")
      expect(json["status"]).to eq("canceled")
      expect(invocation.reload.approval_state).to eq("expired")
    end

    it "flags a running turn for a boundary cancel" do
      turn.update!(status: "running")
      post "/silas/api/v1/turns/#{turn.id}/cancel"
      expect(json["cancel"]).to eq("cancel_requested")
      expect(json["status"]).to eq("running")
    end
  end

  describe "approvals" do
    before { allow_api! }

    it "lists what's parked, approves it with the api actor, and re-enqueues the loop" do
      get "/silas/api/v1/sessions/#{session.id}/approvals"
      expect(json["approvals"].sole["tool_name"]).to eq("issue_refund")

      expect {
        post "/silas/api/v1/approvals/#{invocation.id}/approve"
      }.to have_enqueued_job(Silas::AgentLoopJob)
      expect(json["approval_state"]).to eq("approved")
      expect(json["approved_by"]).to eq("api")
    end

    it "declines with a reason the model sees as {denied:}" do
      post "/silas/api/v1/approvals/#{invocation.id}/decline", params: { reason: "amount too high" }
      expect(json["approval_state"]).to eq("declined")
      expect(json["result"]).to eq("denied" => "amount too high")
    end

    it "409s a verdict on an already-settled invocation" do
      invocation.update!(approval_state: "approved", status: "completed")
      post "/silas/api/v1/approvals/#{invocation.id}/approve"
      expect(response).to have_http_status(:conflict)
    end
  end
end
