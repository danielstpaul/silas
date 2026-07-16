require "rails_helper"

RSpec.describe "the inbox", type: :request do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create!(agent_name: "refunds") }
  let!(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund order 42", status: "waiting") }
  let!(:step) { Silas::Step.create!(turn: turn, index: 0, status: "completed", model: "claude-sonnet-5", input_tokens: 100, output_tokens: 50) }
  let!(:invocation) do
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "issue_refund",
                                  effect_mode: "at_most_once", arguments: { "amount" => 120 },
                                  approval_state: "required")
  end

  def allow_all!
    Silas.configure { |c| c.inbox_auth = ->(_controller) {} } # pass = do not render
  end

  describe "deny-by-default auth" do
    it "404s every route when nothing is configured" do
      get "/silas/inbox"
      expect(response).to have_http_status(:not_found)
      get "/silas/inbox/sessions/#{session.id}"
      expect(response).to have_http_status(:not_found)
      post "/silas/inbox/invocations/#{invocation.id}/approve"
      expect(response).to have_http_status(:not_found)
    end

    it "allows reads when the host lambda passes" do
      allow_all!
      get "/silas/inbox"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("refunds")
    end

    it "public-read renders reads anonymously but STILL gates approve/decline" do
      Silas.configure { |c| c.inbox_public_read = true } # inbox_auth stays deny-by-default
      get "/silas/inbox/sessions/#{session.id}"
      expect(response).to have_http_status(:ok)
      post "/silas/inbox/invocations/#{invocation.id}/approve"
      expect(response).to have_http_status(:not_found) # writes never public
    end

    it "passes the controller instance to the auth lambda" do
      seen = nil
      Silas.configure { |c| c.inbox_auth = ->(controller) { seen = controller } }
      get "/silas/inbox"
      expect(seen).to be_a(Silas::Inbox::SessionsController)
    end
  end

  describe "session views" do
    before { allow_all! }

    it "lists sessions with a pending-approval badge" do
      get "/silas/inbox"
      expect(response.body).to include("awaiting approval").or include("to approve")
    end

    it "renders the live trace with the approval card and cost" do
      get "/silas/inbox/sessions/#{session.id}"
      expect(response.body).to include("issue_refund")
      expect(response.body).to include("Approval needed")
      expect(response.body).to include("$") # priced cost shown
    end
  end

  describe "approvals (same code path as Slack/email)" do
    before { allow_all! }

    it "approve! resolves the invocation and re-enqueues the loop" do
      expect {
        post "/silas/inbox/invocations/#{invocation.id}/approve"
      }.to have_enqueued_job(Silas::AgentLoopJob)
      expect(invocation.reload).to have_attributes(approval_state: "approved", approved_by: "inbox")
      expect(response).to redirect_to("/silas/inbox/sessions/#{session.id}")
    end

    it "decline-with-note records the reason and feeds {denied:} to the agent" do
      post "/silas/inbox/invocations/#{invocation.id}/decline", params: { reason: "amount too high" }
      expect(invocation.reload).to have_attributes(approval_state: "declined", decline_reason: "amount too high")
      expect(invocation.result).to eq("denied" => "amount too high")
    end

    it "declining an already-resolved invocation redirects with an alert, not a 500" do
      invocation.update!(approval_state: "approved", status: "completed")
      post "/silas/inbox/invocations/#{invocation.id}/decline"
      expect(response).to redirect_to("/silas/inbox/sessions/#{session.id}")
      expect(flash[:alert]).to be_present
    end
  end
end
