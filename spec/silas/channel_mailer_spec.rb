require "rails_helper"

# The approval email is the ONLY thing that tells a human a turn is parked on
# the email channel. It had no spec, and its template called a route helper
# that does not exist — so rendering raised and the notification was never
# delivered. These specs render for real and verify the links round-trip.
RSpec.describe Silas::ChannelMailer do
  let(:session) { Silas::Session.create! }
  let(:turn) { Silas::Turn.create!(session: session, index: 0, input: "refund", status: "waiting") }
  let(:step) { Silas::Step.create!(turn: turn, index: 0, status: "completed") }
  let(:invocation) do
    Silas::ToolInvocation.create!(step: step, turn: turn, tool_call_id: "t0", tool_name: "issue_refund",
                                  effect_mode: "at_most_once", arguments: { "amount_pence" => 4800 },
                                  approval_state: "required")
  end

  describe "#answer" do
    it "renders the agent's reply as plain text" do
      mail = described_class.answer(to: "ada@example.com", subject: "Re: my order",
                                    text: "Refunded £48.00.")
      expect(mail.to).to eq([ "ada@example.com" ])
      expect(mail.subject).to eq("Re: my order")
      expect(mail.body.to_s).to include("Refunded £48.00.")
    end
  end

  describe "#approval" do
    subject(:mail) do
      described_class.approval(to: "manager@example.com", subject: "Approval needed", invocation: invocation)
    end

    it "renders without raising (the template's route helper must resolve)" do
      expect { mail.body.to_s }.not_to raise_error
      expect(mail.to).to eq([ "manager@example.com" ])
    end

    it "shows the operator WHAT they are approving" do
      body = mail.body.to_s
      expect(body).to include("issue_refund")
      expect(body).to include("4800") # the arguments, so nobody approves blind
    end

    it "embeds two absolute, distinct one-click links" do
      links = mail.body.to_s.scan(%r{https?://\S+/silas/channels/approvals/\S+})
      expect(links.size).to eq(2)
      expect(links.uniq.size).to eq(2) # approve and decline must not be the same URL
    end

    it "signs tokens that verify back to THIS invocation with the right action" do
      approve_token, decline_token =
        mail.body.to_s.scan(%r{/silas/channels/approvals/([^\s/]+)}).flatten

      approve = Silas::Channel.verify_token(CGI.unescape(approve_token))
      decline = Silas::Channel.verify_token(CGI.unescape(decline_token))

      expect(approve).to include("id" => invocation.id, "action" => "approve")
      expect(decline).to include("id" => invocation.id, "action" => "decline")
    end

    it "warns that the links are bearer credentials" do
      expect(mail.body.to_s).to match(/do not forward/i)
    end
  end
end
