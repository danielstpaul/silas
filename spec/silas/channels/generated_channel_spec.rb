require "rails_helper"

# Exercises the shape `rails g silas:channel` produces, wired into the dummy
# app exactly as a host would wire it: a Channel subclass under app/agent/, a
# webhook controller under app/controllers/agent/, and a host route. The
# generator spec checks what gets WRITTEN; this checks that it WORKS.
RSpec.describe "a generated channel", type: :request do
  let(:secret) { "coo-coo" }

  def signed_post(payload, timestamp: Time.current.to_i, secret: self.secret)
    body = payload.to_json
    signature = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    post "/agent/channels/pigeon", params: body,
         headers: { "CONTENT_TYPE" => "application/json",
                    "X-Signature" => signature,
                    "X-Signature-Timestamp" => timestamp.to_s }
  end

  before do
    Agent::Channels::Pigeon.reset!
    allow(Silas.agent).to receive(:start).and_call_original
  end

  describe "inbound" do
    it "starts a session for a new thread, namespaced by channel" do
      expect { signed_post({ conversation_id: "coop-1", text: "any post today?" }) }
        .to change(Silas::Session, :count).by(1)

      expect(response).to have_http_status(:ok)
      session = Silas::Session.last
      expect(session.channel).to eq("pigeon")
      expect(session.continuation_token).to eq("pigeon:agent:coop-1")
      expect(session.metadata).to eq({ "pigeon" => { "coop" => "coop-1" } })
    end

    it "continues the existing session when the same thread replies" do
      signed_post({ conversation_id: "coop-1", text: "first" })
      session = Silas::Session.last
      allow(Silas::Session).to receive(:find_by).and_return(session)
      allow(session).to receive(:continue)

      expect { signed_post({ conversation_id: "coop-1", text: "second" }) }
        .not_to change(Silas::Session, :count)
      expect(session).to have_received(:continue).with(input: "second")
    end

    it "refuses a request signed with the wrong secret" do
      expect { signed_post({ conversation_id: "coop-1", text: "hi" }, secret: "forged") }
        .not_to change(Silas::Session, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a captured request replayed after the window" do
      expect { signed_post({ conversation_id: "coop-1", text: "hi" }, timestamp: 10.minutes.ago.to_i) }
        .not_to change(Silas::Session, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it "ignores an empty message rather than starting an empty session" do
      expect { signed_post({ conversation_id: "coop-1", text: "" }) }
        .not_to change(Silas::Session, :count)
      expect(response).to have_http_status(:ok)
    end

    # Single-active-turn is an invariant, not a queue. The generated controller
    # swallows it so the vendor doesn't retry forever.
    it "answers 200 when a reply lands mid-turn" do
      signed_post({ conversation_id: "coop-1", text: "first" })
      allow_any_instance_of(Silas::Session).to receive(:continue).and_raise(Silas::TurnInProgressError)

      signed_post({ conversation_id: "coop-1", text: "second" })
      expect(response).to have_http_status(:ok)
    end
  end

  describe "outbound" do
    before { Silas::Registry.install!(root: DummyApp.root) } # wires the real channel_resolver

    let(:session) do
      Silas::Session.create!(channel: "pigeon", continuation_token: "pigeon:coop-9",
                             metadata: { "pigeon" => { "coop" => "coop-9" } })
    end
    let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "hi", status: "running") }
    let(:step) { Silas::Step.create!(turn: turn, index: 0) }
    let(:invocation) do
      Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0",
                                    tool_name: "refund_order", effect_mode: "transactional",
                                    arguments: { "amount" => 5000 },
                                    approval_state: "required") # parked, as it would be at delivery time
    end

    it "resolves the channel from the session and delivers the answer" do
      Silas::Channel.for_session(session).deliver_answer(session: session, text: "two parcels")
      expect(Agent::Channels::Pigeon.sent).to eq([ { to: "coop-9", text: "two parcels" } ])
    end

    it "mints working approve/decline links that any transport can carry" do
      Silas::Channel.for_session(session).deliver_approval(session: session, invocation: invocation)
      delivered = Agent::Channels::Pigeon.sent.first

      expect(delivered[:approve]).to start_with("http://example.test/silas/channels/approvals/")
      expect(delivered[:approve]).not_to eq(delivered[:decline])

      # The link is the credential: following it must settle THIS invocation.
      # Use the generated path verbatim — re-encoding a signed token is exactly
      # the mistake this asserts against.
      get URI.parse(delivered[:approve]).path
      expect(response).to have_http_status(:ok) # the confirm page
      post URI.parse(delivered[:approve]).path
      expect(response).to have_http_status(:ok)
      expect(invocation.reload.approval_state).to eq("approved")
    end

    it "raises with the fix when no host is configured, rather than minting a dead link" do
      allow(Rails.application.config.action_mailer).to receive(:default_url_options).and_return({})
      allow(Rails.application.routes).to receive(:default_url_options).and_return({})

      expect { Silas::Channel.approval_url(invocation, :approve) }
        .to raise_error(Silas::Error, /needs a host.*default_url_options/m)
    end
  end
end
