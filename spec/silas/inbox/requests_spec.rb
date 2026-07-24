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

  describe "web chat" do
    it "gates composing behind write auth even in public-read mode" do
      Silas.configure { |c| c.inbox_public_read = true } # inbox_auth stays deny-by-default
      post "/silas/inbox/sessions", params: { input: "hi" }
      expect(response).to have_http_status(:not_found)
      post "/silas/inbox/sessions/#{session.id}/turns", params: { input: "hi" }
      expect(response).to have_http_status(:not_found)
    end

    it "starts a session from the index composer and redirects to it" do
      allow_all!
      expect {
        post "/silas/inbox/sessions", params: { input: "hello there" }
      }.to change(Silas::Session, :count).by(1)
      created = Silas::Session.order(:id).last
      expect(response).to redirect_to("/silas/inbox/sessions/#{created.id}")
      expect(created.turns.sole.input).to eq("hello there")
      expect(created.channel).to be_nil # "direct": no outbound ChannelDeliveryJobs for web chat
    end

    it "renders the composer on the session page" do
      allow_all!
      get "/silas/inbox/sessions/#{session.id}"
      expect(response.body).to include("composer")
    end

    it "appends a turn to a settled session" do
      allow_all!
      turn.finish!(:completed)
      expect {
        post "/silas/inbox/sessions/#{session.id}/turns", params: { input: "and another thing" }
      }.to change { session.turns.count }.by(1)
      expect(response).to redirect_to("/silas/inbox/sessions/#{session.id}")
      expect(session.turns.order(:index).last.input).to eq("and another thing")
    end

    it "surfaces turn-in-progress as an inline alert, not a crash" do
      allow_all!
      post "/silas/inbox/sessions/#{session.id}/turns", params: { input: "impatient" } # fixture turn is active
      expect(response).to redirect_to("/silas/inbox/sessions/#{session.id}")
      expect(flash[:alert]).to match(/already running/)
    end

    it "rejects a blank message with an alert" do
      allow_all!
      expect {
        post "/silas/inbox/sessions", params: { input: "   " }
      }.not_to change(Silas::Session, :count)
      expect(flash[:alert]).to be_present
    end

    it "surfaces an unknown named agent as an alert, not a 500" do
      allow_all!
      post "/silas/inbox/sessions", params: { input: "hi", agent: "nonexistent" }
      expect(response).to redirect_to("/silas/inbox/sessions")
      expect(flash[:alert]).to match(/unknown agent/)
    end
  end

  describe "audit trail" do
    before { allow_all! }

    it "renders arguments and the approver for a completed approved invocation" do
      invocation.update!(approval_state: "approved", approved_by: "manager@co",
                         status: "completed", result: { "refunded" => true })
      get "/silas/inbox/sessions/#{session.id}"
      expect(response.body).to include("120")                      # the arguments, always visible
      expect(response.body).to include("approved by manager@co")   # who held the lever
      expect(response.body).to include("refunded")
    end

    it "renders the error for a failed invocation" do
      invocation.update!(approval_state: nil, status: "failed",
                         error: "RuntimeError: bank exploded")
      get "/silas/inbox/sessions/#{session.id}"
      expect(response.body).to include("bank exploded")
    end

    it "renders who declined and why" do
      invocation.update!(approval_state: "declined", approved_by: "cfo", status: "failed",
                         decline_reason: "amount too high", result: { "denied" => "amount too high" })
      get "/silas/inbox/sessions/#{session.id}"
      expect(response.body).to include("declined by cfo")
      expect(response.body).to include("amount too high")
    end

    it "filters the index to sessions with pending approvals via ?pending=1" do
      idle = Silas::Session.create!(agent_name: "idle") # no approvals — filtered out
      get "/silas/inbox/sessions", params: { pending: 1 }
      expect(response.body).to include("/silas/inbox/sessions/#{session.id}")
      expect(response.body).not_to include("/silas/inbox/sessions/#{idle.id}")
    end
  end

  describe "cancel button" do
    it "is write-gated even in public-read mode" do
      Silas.configure { |c| c.inbox_public_read = true }
      post "/silas/inbox/turns/#{turn.id}/cancel"
      expect(response).to have_http_status(:not_found)
    end

    it "cancels a parked turn immediately and expires its approvals" do
      allow_all!
      post "/silas/inbox/turns/#{turn.id}/cancel" # fixture turn is 'waiting' (parked)
      expect(turn.reload.status).to eq("canceled")
      expect(invocation.reload.approval_state).to eq("expired")
      expect(response).to redirect_to("/silas/inbox/sessions/#{session.id}")
      expect(flash[:notice]).to match(/canceled/i)
    end

    it "flags a running turn for a step-boundary cancel" do
      allow_all!
      turn.update!(status: "running")
      post "/silas/inbox/turns/#{turn.id}/cancel"
      expect(turn.reload.cancel_requested_at).to be_present
      expect(turn.status).to eq("running") # honored at the boundary, not aborted
      expect(flash[:notice]).to match(/next step boundary/)
    end
  end
end
