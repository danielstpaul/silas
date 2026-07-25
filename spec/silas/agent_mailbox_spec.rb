require "rails_helper"
require "mail"

# Inbound email: one of the two shipped channels, previously untested. The
# threading rule is the load-bearing part — get it wrong and every reply starts
# a NEW session instead of continuing the conversation.
RSpec.describe Silas::AgentMailbox do
  before do
    Agent::Channels::Recorder.reset!
    Silas.configure do |c|
      c.channel_resolver = ->(name) { Agent::Channels::Recorder if name == "email" }
      c.tool_resolver = ->(_n) { raise "no tools in this spec" }
    end
  end

  def mail_for(body: "please refund my order", **headers)
    Mail.new do
      from    headers[:from] || "ada@example.com"
      to      "support@shop.test"
      subject headers[:subject] || "My order"
      message_id headers[:message_id] || "<msg-1@example.com>"
      in_reply_to headers[:in_reply_to] if headers[:in_reply_to]
      references  headers[:references]  if headers[:references]
      body body
    end
  end

  # Drive #process without the ActionMailbox/ActiveStorage ingress machinery:
  # the mailbox's own logic is what's under test, not Rails' plumbing.
  def deliver(mail)
    mailbox = described_class.allocate
    mailbox.define_singleton_method(:mail) { mail }
    mailbox.process
  end

  describe ".thread_key — the rule that makes replies continue, not restart" do
    it "uses the References head when present (the thread ROOT, not the parent)" do
      mail = mail_for(references: [ "<root@example.com>", "<parent@example.com>" ],
                      message_id: "<child@example.com>")
      expect(described_class.thread_key(mail)).to eq("root@example.com")
    end

    it "falls back to In-Reply-To when there are no References" do
      mail = mail_for(in_reply_to: "<parent@example.com>", message_id: "<child@example.com>")
      expect(described_class.thread_key(mail)).to eq("parent@example.com")
    end

    it "falls back to this message's own id for a brand-new thread" do
      expect(described_class.thread_key(mail_for)).to eq("msg-1@example.com")
    end
  end

  describe "#process" do
    it "starts a session stamped with the channel and the thread key" do
      expect { deliver(mail_for) }.to change(Silas::Session, :count).by(1)

      session = Silas::Session.last
      expect(session.channel).to eq("recorder")
      expect(session.continuation_token).to eq("recorder:msg-1@example.com")
      expect(session.turns.sole.input).to eq("please refund my order")
      expect(session.metadata.dig("email", "from")).to eq("ada@example.com")
      expect(session.metadata.dig("email", "subject")).to eq("My order")
    end

    it "continues the SAME session when a reply arrives in the thread" do
      deliver(mail_for)
      Silas::Session.last.turns.each { |t| t.finish!(:completed) }

      reply = mail_for(body: "any update?", message_id: "<msg-2@example.com>",
                       references: [ "<msg-1@example.com>" ])
      expect { deliver(reply) }.not_to change(Silas::Session, :count)
      expect(Silas::Session.last.turns.count).to eq(2)
      expect(Silas::Session.last.turns.last.input).to eq("any update?")
    end

    it "extracts the text part of a multipart email, not the HTML" do
      multipart = Mail.new do
        from "ada@example.com"
        to "support@shop.test"
        subject "My order"
        message_id "<mp-1@example.com>"
        text_part { body "the plain text body" }
        html_part { body "<p>the HTML body</p>" }
      end

      deliver(multipart)
      expect(Silas::Session.last.turns.sole.input).to eq("the plain text body")
    end

    it "drops a reply that lands mid-turn rather than raising (single-active-turn)" do
      deliver(mail_for) # leaves an active turn
      reply = mail_for(body: "impatient", message_id: "<msg-3@example.com>",
                       references: [ "<msg-1@example.com>" ])

      expect { deliver(reply) }.not_to raise_error
      expect(Silas::Session.last.turns.count).to eq(1)
    end

    it "fails loudly when no email channel is defined (misconfiguration, not silence)" do
      Silas.configure { |c| c.channel_resolver = ->(_n) { nil } }
      expect { deliver(mail_for) }.to raise_error(Silas::Error, /app\/agent\/channels\/email/)
    end
  end
end
