require "rails_helper"

# The email approve/decline link is a URL that settles a money-moving tool call
# for anyone holding it. Its only defence is a signed, expiring token — and the
# controller consuming that token had no spec at all. These pin the security
# properties, not just the happy path.
RSpec.describe "the email approval links", type: :request do
  include ActiveJob::TestHelper

  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund", status: "waiting") }
  let(:step) { Silas::Step.create!(turn: turn, index: 0, status: "completed") }
  let!(:invocation) do
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "issue_refund",
                                  effect_mode: "at_most_once", arguments: { "amount_pence" => 4800 },
                                  approval_state: "required")
  end

  def token_for(action) = Silas::Channel.token_for(invocation, action)

  describe "token integrity" do
    it "refuses a tampered token (422, nothing settled)" do
      get "/silas/channels/approvals/#{token_for('approve')}tampered"
      expect(response).to have_http_status(:unprocessable_entity)

      post "/silas/channels/approvals/#{token_for('approve')}tampered"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invocation.reload.approval_state).to eq("required")
    end

    it "refuses a garbage token" do
      post "/silas/channels/approvals/not-a-real-token"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invocation.reload.approval_state).to eq("required")
    end

    it "refuses a token past its expiry (links must not work forever)" do
      token = token_for("approve")
      travel_to(Silas.config.approval_ttl.from_now + 1.minute) do
        post "/silas/channels/approvals/#{token}"
        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(invocation.reload.approval_state).to eq("required")
    end

    it "does not accept a token signed for a DIFFERENT purpose" do
      foreign = Rails.application.message_verifier("something/else")
                     .generate({ "id" => invocation.id, "action" => "approve" })
      post "/silas/channels/approvals/#{foreign}"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invocation.reload.approval_state).to eq("required")
    end
  end

  describe "GET is safe" do
    it "renders a confirmation page WITHOUT settling anything" do
      get "/silas/channels/approvals/#{token_for('approve')}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("issue_refund")
      # The critical property: a link preview, scanner, or prefetch must not
      # approve a refund.
      expect(invocation.reload.approval_state).to eq("required")
    end
  end

  describe "POST settles through the same approve!/decline! as every surface" do
    it "approves and resumes the turn" do
      expect {
        post "/silas/channels/approvals/#{token_for('approve')}"
      }.to have_enqueued_job(Silas::AgentLoopJob)
      expect(response).to have_http_status(:ok)
      expect(invocation.reload).to have_attributes(approval_state: "approved", approved_by: "email")
    end

    it "declines, recording the reason the agent will see" do
      post "/silas/channels/approvals/#{token_for('decline')}"
      expect(invocation.reload).to have_attributes(approval_state: "declined", approved_by: "email")
      expect(invocation.result).to eq("denied" => "declined by email")
    end

    it "handles a REPLAYED link on an already-settled invocation (422, not 500)" do
      token = token_for("approve")
      post "/silas/channels/approvals/#{token}"
      expect(invocation.reload.approval_state).to eq("approved")

      # Same still-valid token, clicked again — e.g. forwarded email.
      post "/silas/channels/approvals/#{token}"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(invocation.reload.approval_state).to eq("approved") # unchanged
    end

    it "422s rather than 500s when the invocation has been expired by the sweeper" do
      invocation.update!(approval_state: "expired", status: "failed")
      post "/silas/channels/approvals/#{token_for('approve')}"
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
