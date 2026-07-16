require "rails_helper"

RSpec.describe Silas::Slack do
  let(:secret) { "8f742231b10e8888abcd99yyyzzz85a5" }

  def signature_for(timestamp:, body:, sec: secret)
    "v0=" + OpenSSL::HMAC.hexdigest("SHA256", sec, "v0:#{timestamp}:#{body}")
  end

  describe ".verify_signature" do
    let(:now) { 1_700_000_000 }
    let(:body) { "token=abc&team_id=T1" }

    it "accepts a genuine, fresh signature" do
      ts = now.to_s
      expect(described_class.verify_signature(
        signing_secret: secret, timestamp: ts, body: body,
        signature: signature_for(timestamp: ts, body: body), now: now
      )).to be(true)
    end

    it "rejects a wrong secret" do
      ts = now.to_s
      expect(described_class.verify_signature(
        signing_secret: secret, timestamp: ts, body: body,
        signature: signature_for(timestamp: ts, body: body, sec: "wrong"), now: now
      )).to be(false)
    end

    it "rejects a stale timestamp (replay window)" do
      ts = (now - 600).to_s
      expect(described_class.verify_signature(
        signing_secret: secret, timestamp: ts, body: body,
        signature: signature_for(timestamp: ts, body: body), now: now
      )).to be(false)
    end

    it "rejects when the secret is blank" do
      ts = now.to_s
      expect(described_class.verify_signature(
        signing_secret: nil, timestamp: ts, body: body, signature: "v0=x", now: now
      )).to be(false)
    end
  end

  describe ".approval_blocks" do
    it "builds Approve/Decline buttons carrying the invocation id" do
      inv = Struct.new(:id, :tool_name, :arguments).new(7, "issue_refund", { "amount" => 500 })
      blocks = described_class.approval_blocks(inv)
      buttons = blocks.last["elements"]
      expect(buttons.map { |b| b["action_id"] }).to eq(%w[silas_approve silas_decline])
      expect(buttons.map { |b| b["value"] }).to eq(%w[7 7])
      expect(blocks.first["text"]["text"]).to include("issue_refund")
    end
  end
end
