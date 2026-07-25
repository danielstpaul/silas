require "rails_helper"

# The Slack webhook is an UNAUTHENTICATED public endpoint whose only defence is
# the request signature — and whose actions route can approve a money-moving
# tool call. Silas::Slack.verify_signature was unit-tested; the controller that
# calls it was not, so nothing proved an unsigned request is actually refused
# end to end. That is what these specs pin.
RSpec.describe "the Slack channel", type: :request do
  include ActiveJob::TestHelper

  SIGNING_SECRET = "shhh-signing-secret".freeze

  before do
    Agent::Channels::Recorder.reset!
    Silas.configure do |c|
      c.slack_signing_secret = SIGNING_SECRET
      # The controller resolves "slack" through the registry; the dummy app's
      # Recorder channel stands in for a real transport.
      c.channel_resolver = ->(name) { Agent::Channels::Recorder if name == "slack" }
      c.tool_resolver = ->(_n) { raise "no tools in this spec" }
    end
  end

  # Slack's v0 scheme: HMAC-SHA256 over "v0:{timestamp}:{raw body}".
  def signed_headers(body, timestamp: Time.now.to_i, secret: SIGNING_SECRET)
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{timestamp}:#{body}")
    { "X-Slack-Request-Timestamp" => timestamp.to_s, "X-Slack-Signature" => "v0=#{digest}",
      "CONTENT_TYPE" => "application/json" }
  end

  def post_event(payload, **header_opts)
    body = JSON.generate(payload)
    post "/silas/channels/slack/events", params: body, headers: signed_headers(body, **header_opts)
  end

  def message_event(text: "refund my order", ts: "1700000000.1", thread_ts: nil, **event_extra)
    { type: "event_callback", team_id: "T1",
      event: { type: "message", channel: "C1", ts: ts, thread_ts: thread_ts,
               user: "U1", text: text }.merge(event_extra) }
  end

  describe "signature verification (the only thing standing in front of this endpoint)" do
    it "401s an unsigned request and dispatches nothing" do
      expect {
        post "/silas/channels/slack/events", params: JSON.generate(message_event),
             headers: { "CONTENT_TYPE" => "application/json" }
      }.not_to change(Silas::Session, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s a request signed with the wrong secret" do
      body = JSON.generate(message_event)
      post "/silas/channels/slack/events", params: body,
           headers: signed_headers(body, secret: "attacker-guess")
      expect(response).to have_http_status(:unauthorized)
      expect(Silas::Session.count).to eq(0)
    end

    it "401s a correctly-signed but STALE request (replay window)" do
      # Genuine signature, six minutes old — outside Slack's 300s window.
      post_event(message_event, timestamp: 6.minutes.ago.to_i)
      expect(response).to have_http_status(:unauthorized)
      expect(Silas::Session.count).to eq(0)
    end

    it "401s the interactive actions route too" do
      post "/silas/channels/slack/actions", params: { payload: "{}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "inbound events" do
    it "echoes Slack's url_verification challenge" do
      post_event({ type: "url_verification", challenge: "abc123" })
      expect(JSON.parse(response.body)["challenge"]).to eq("abc123")
    end

    it "starts a session keyed to the Slack thread, stamped with the channel" do
      expect { post_event(message_event) }.to change(Silas::Session, :count).by(1)
      expect(response).to have_http_status(:ok)

      session = Silas::Session.last
      expect(session.channel).to eq("recorder") # the resolved channel's own name
      expect(session.continuation_token).to eq("recorder:T1:C1:1700000000.1")
      expect(session.turns.sole.input).to eq("refund my order")
      expect(session.metadata.dig("slack", "user")).to eq("U1")
    end

    it "continues the SAME session for a reply in the same thread" do
      post_event(message_event)
      Silas::Session.last.turns.each { |t| t.finish!(:completed) }

      expect {
        post_event(message_event(text: "any update?", ts: "1700000009.9", thread_ts: "1700000000.1"))
      }.not_to change(Silas::Session, :count)
      expect(Silas::Session.last.turns.count).to eq(2)
    end

    it "ignores Slack's at-least-once retries" do
      body = JSON.generate(message_event)
      expect {
        post "/silas/channels/slack/events", params: body,
             headers: signed_headers(body).merge("X-Slack-Retry-Num" => "1")
      }.not_to change(Silas::Session, :count)
      expect(response).to have_http_status(:ok)
    end

    it "ignores the bot's own messages and edits/joins (no infinite loop)" do
      expect { post_event(message_event(bot_id: "B1")) }.not_to change(Silas::Session, :count)
      expect { post_event(message_event(subtype: "message_changed")) }.not_to change(Silas::Session, :count)
    end

    it "drops a message that arrives mid-turn rather than 500ing (single-active-turn)" do
      post_event(message_event) # leaves an active turn
      expect {
        post_event(message_event(text: "impatient", ts: "1700000009.9", thread_ts: "1700000000.1"))
      }.not_to raise_error
      expect(response).to have_http_status(:ok)
    end
  end

  describe "interactive approve/decline buttons" do
    let(:session) { Silas::Session.create! }
    let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund", status: "waiting") }
    let(:step) { Silas::Step.create!(turn: turn, index: 0, status: "completed") }
    let!(:invocation) do
      Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "issue_refund",
                                    effect_mode: "at_most_once", arguments: { "amount" => 4800 },
                                    approval_state: "required")
    end

    def post_action(action_id)
      payload = JSON.generate(
        "user" => { "username" => "ada" },
        "actions" => [ { "action_id" => action_id, "value" => invocation.id.to_s } ]
      )
      body = { payload: payload }.to_query
      digest = OpenSSL::HMAC.hexdigest("SHA256", SIGNING_SECRET, "v0:#{Time.now.to_i}:#{body}")
      post "/silas/channels/slack/actions", params: { payload: payload },
           headers: { "X-Slack-Request-Timestamp" => Time.now.to_i.to_s, "X-Slack-Signature" => "v0=#{digest}" }
    end

    it "approves through the SAME approve! as the inbox, attributing the Slack user" do
      expect { post_action("silas_approve") }.to have_enqueued_job(Silas::AgentLoopJob)
      expect(invocation.reload).to have_attributes(approval_state: "approved", approved_by: "slack:ada")
      expect(JSON.parse(response.body)["text"]).to match(/Approved/)
    end

    it "declines and feeds {denied:} back to the agent" do
      post_action("silas_decline")
      expect(invocation.reload).to have_attributes(approval_state: "declined", approved_by: "slack:ada")
      expect(invocation.result).to eq("denied" => "declined in Slack")
    end

    it "reports a double-click on an already-settled invocation instead of 500ing" do
      invocation.update!(approval_state: "approved", status: "completed")
      post_action("silas_approve")
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["text"]).to match(/Could not record/)
    end
  end
end
