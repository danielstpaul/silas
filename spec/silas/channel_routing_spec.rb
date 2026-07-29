require "rails_helper"
require "mail"

# Which agent an inbound thread wakes. Before routing, dispatch could only ever
# call Silas.agent.start, so an app with named staff had no way to send a Slack
# channel to the bookkeeper or support@ to the clerk — every surface landed on
# the root agent.
RSpec.describe "channel routing", type: :request do
  include ActiveJob::TestHelper

  ROUTING_SECRET = "shhh-routing-secret".freeze

  # Routes first, then install! — that is boot order, and it means every example
  # here also runs the boot-time route check.
  def configure!(routes)
    Silas.config.channel_routes = routes
    Silas::Registry.install!(root: DummyApp.root)
    Silas.config.channel_resolver = ->(name) { Agent::Channels::Recorder if %w[slack email].include?(name) }
    Silas.config.tool_resolver = ->(_n) { raise "no tools in this spec" }
    Silas.config.slack_signing_secret = ROUTING_SECRET
  end

  def post_slack(channel: "C1", text: "file this", ts: "1700000000.1", thread_ts: nil)
    body = JSON.generate(type: "event_callback", team_id: "T1",
                         event: { type: "message", channel: channel, ts: ts,
                                  thread_ts: thread_ts, user: "U1", text: text })
    timestamp = Time.now.to_i
    digest = OpenSSL::HMAC.hexdigest("SHA256", ROUTING_SECRET, "v0:#{timestamp}:#{body}")
    post "/silas/channels/slack/events", params: body,
         headers: { "X-Slack-Request-Timestamp" => timestamp.to_s, "X-Slack-Signature" => "v0=#{digest}",
                    "CONTENT_TYPE" => "application/json" }
  end

  def deliver_email(to: "support@shop.test", cc: nil, message_id: "<m1@example.com>")
    mail = Mail.new do
      from "ada@example.com"
      to to
      cc cc if cc
      subject "My order"
      message_id message_id
      body "please file this"
    end
    mailbox = Silas::AgentMailbox.allocate
    mailbox.define_singleton_method(:mail) { mail }
    mailbox.process
  end

  before { Agent::Channels::Recorder.reset! }

  describe "Slack" do
    it "routes a Slack channel to the named agent that owns it" do
      configure!("slack" => { "C0FILING" => "filer" })

      expect { post_slack(channel: "C0FILING") }.to change(Silas::Session, :count).by(1)
      session = Silas::Session.last
      expect(session.agent_name).to eq("filer")            # the loop swaps in the filer's scope
      expect(session.continuation_token).to eq("recorder:filer:T1:C0FILING:1700000000.1")
    end

    it "sends an unrouted channel to the root agent" do
      configure!("slack" => { "C0FILING" => "filer" })

      post_slack(channel: "C0OTHER")
      session = Silas::Session.last
      expect(session.agent_name).to eq("agent")
      expect(session.continuation_token).to eq("recorder:agent:T1:C0OTHER:1700000000.1")
    end

    it "keeps a routed thread on its agent when the reply arrives" do
      configure!("slack" => { "C0FILING" => "filer" })

      post_slack(channel: "C0FILING")
      Silas::Session.last.turns.each { |t| t.finish!(:completed) }

      expect { post_slack(channel: "C0FILING", text: "any update?", ts: "1700000009.9",
                          thread_ts: "1700000000.1") }.not_to change(Silas::Session, :count)
      expect(Silas::Session.last.turns.count).to eq(2)
    end
  end

  describe "email" do
    it "routes a recipient address to the named agent that owns it" do
      configure!("email" => { "filing@shop.test" => "filer" })

      expect { deliver_email(to: "filing@shop.test") }.to change(Silas::Session, :count).by(1)
      session = Silas::Session.last
      expect(session.agent_name).to eq("filer")
      expect(session.continuation_token).to eq("recorder:filer:m1@example.com")
    end

    it "matches the address case-insensitively, and matches on Cc as well as To" do
      configure!("email" => { "filing@shop.test" => "filer" })

      deliver_email(to: "Filing@Shop.Test")
      expect(Silas::Session.last.agent_name).to eq("filer")

      deliver_email(to: "someone@shop.test", cc: "filing@shop.test", message_id: "<m2@example.com>")
      expect(Silas::Session.last.agent_name).to eq("filer")
    end

    it "sends mail to an unrouted address to the root agent" do
      configure!("email" => { "filing@shop.test" => "filer" })

      deliver_email(to: "support@shop.test")
      expect(Silas::Session.last.agent_name).to eq("agent")
    end

    it "leaves the root agent in charge when nothing is routed at all" do
      configure!({})

      deliver_email
      expect(Silas::Session.last.agent_name).to eq("agent")
    end
  end

  describe "an unknown agent name" do
    # Silas.agent(name) raises on an unknown name, so a typo'd route has to be
    # caught before a live thread depends on it.
    it "fails the boot that installs it, naming the staff that do exist" do
      Silas.config.channel_routes = { "slack" => { "C0FILING" => "filerr" } }

      expect { Silas::Registry.install!(root: DummyApp.root) }
        .to raise_error(Silas::Error, /channel_routes\["slack"\]\["c0filing"\].*"filerr".*known: filer, scribe/m)
    end

    it "accepts the root agent as an explicit destination" do
      expect { configure!("email" => { "support@shop.test" => "agent" }) }.not_to raise_error

      deliver_email(to: "support@shop.test")
      expect(Silas::Session.last.agent_name).to eq("agent")
    end

    # Assigned after boot, so the boot check never saw it. Raising here would
    # 500 the webhook; Slack retries, the retry guard drops the retry, and the
    # message is gone.
    it "does not raise into the webhook — it wakes the root agent and logs" do
      configure!({})
      Silas.config.channel_routes = { "slack" => { "C0FILING" => "ghost" } }
      expect(Rails.logger).to receive(:error).with(/unknown agent "ghost"/)

      expect { post_slack(channel: "C0FILING") }.to change(Silas::Session, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(Silas::Session.last.agent_name).to eq("agent")
    end
  end

  describe "the continuation token" do
    it "gives each agent its own key space on a shared transport" do
      configure!({})

      filer  = Agent::Channels::Recorder.dispatch(thread_key: "T9", input: "hi", agent: "filer")
      scribe = Agent::Channels::Recorder.dispatch(thread_key: "T9", input: "hi", agent: "scribe")

      expect(filer.id).not_to eq(scribe.id)
      expect(filer.continuation_token).to eq("recorder:filer:T9")
      expect(scribe.continuation_token).to eq("recorder:scribe:T9")
    end

    # Tokens minted before routing existed have no agent segment. They are all
    # root-agent sessions, and they must keep their threads.
    it "finds a session minted under the pre-routing token" do
      configure!({})
      legacy = Silas::Session.create!(channel: "recorder", continuation_token: "recorder:T7")

      expect { Agent::Channels::Recorder.dispatch(thread_key: "T7", input: "still here?") }
        .not_to change(Silas::Session, :count)
      expect(legacy.turns.sole.input).to eq("still here?")
    end

    it "keeps a newly-routed thread on the session it already has" do
      configure!("slack" => { "C0FILING" => "filer" })
      legacy = Silas::Session.create!(channel: "recorder",
                                      continuation_token: "recorder:T1:C0FILING:1700000000.1")

      expect { post_slack(channel: "C0FILING") }.not_to change(Silas::Session, :count)
      expect(legacy.reload.agent_name).to eq("agent") # the thread does not change hands mid-conversation
      expect(legacy.turns.sole.input).to eq("file this")
    end
  end
end
