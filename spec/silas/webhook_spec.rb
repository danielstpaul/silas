require "rails_helper"

RSpec.describe Silas::Webhook do
  let(:secret) { "shhh" }
  let(:body) { '{"text":"hello"}' }

  def sign(payload, prefix: "", digest: :hex, key: secret)
    prefix + described_class.hmac("SHA256", key, payload, digest)
  end

  describe ".verify_hmac" do
    it "accepts a correctly signed request" do
      expect(described_class.verify_hmac(secret: secret, signature: sign(body), payload: body)).to be(true)
    end

    it "rejects a signature computed with a different secret" do
      forged = sign(body, key: "wrong")
      expect(described_class.verify_hmac(secret: secret, signature: forged, payload: body)).to be(false)
    end

    it "rejects when the payload was tampered with after signing" do
      signature = sign(body)
      expect(described_class.verify_hmac(secret: secret, signature: signature,
                                         payload: '{"text":"goodbye"}')).to be(false)
    end

    # Fail-closed is the whole point: a channel whose secret was never
    # configured must reject everything, not wave it through.
    it "rejects when no secret is configured" do
      expect(described_class.verify_hmac(secret: nil, signature: sign(body), payload: body)).to be(false)
      expect(described_class.verify_hmac(secret: "", signature: sign(body), payload: body)).to be(false)
    end

    it "rejects a missing or blank signature" do
      expect(described_class.verify_hmac(secret: secret, signature: nil, payload: body)).to be(false)
      expect(described_class.verify_hmac(secret: secret, signature: "", payload: body)).to be(false)
    end

    it "honours the vendor's prefix" do
      expect(described_class.verify_hmac(secret: secret, signature: sign(body, prefix: "sha256="),
                                         payload: body, prefix: "sha256=")).to be(true)
      # Right digest, wrong label — still not a valid signature.
      expect(described_class.verify_hmac(secret: secret, signature: sign(body),
                                         payload: body, prefix: "sha256=")).to be(false)
    end

    it "supports base64 digests (Shopify, Twilio)" do
      signature = sign(body, digest: :base64)
      expect(described_class.verify_hmac(secret: secret, signature: signature,
                                         payload: body, digest: :base64)).to be(true)
    end

    describe "replay window" do
      let(:now) { 1_700_000_000 }

      it "accepts a fresh timestamp" do
        expect(described_class.verify_hmac(secret: secret, signature: sign(body), payload: body,
                                           timestamp: now - 10, now: now)).to be(true)
      end

      it "rejects a captured request replayed after the window" do
        expect(described_class.verify_hmac(secret: secret, signature: sign(body), payload: body,
                                           timestamp: now - 301, now: now)).to be(false)
      end

      # Clock skew cuts both ways — a timestamp from the future is equally
      # suspect, so the window is absolute.
      it "rejects a timestamp too far in the future" do
        expect(described_class.verify_hmac(secret: secret, signature: sign(body), payload: body,
                                           timestamp: now + 301, now: now)).to be(false)
      end

      it "rejects an unparseable timestamp rather than treating it as epoch-adjacent" do
        expect(described_class.verify_hmac(secret: secret, signature: sign(body), payload: body,
                                           timestamp: "not-a-time", now: now)).to be(false)
      end

      # Documented, deliberate: some vendors send no timestamp at all, and
      # there is no window to enforce without one. The template says so.
      it "skips the window when the vendor sends no timestamp" do
        expect(described_class.verify_hmac(secret: secret, signature: sign(body), payload: body,
                                           timestamp: nil, now: now)).to be(true)
      end
    end

    it "raises on an unknown digest rather than silently failing verification" do
      expect {
        described_class.verify_hmac(secret: secret, signature: "x", payload: body, digest: :rot13)
      }.to raise_error(ArgumentError, /digest must be/)
    end
  end

  # Slack's verifier now delegates here; these pin that the delegation kept
  # Slack's exact scheme (v0 basestring, v0= prefix, blank-timestamp refusal).
  describe "Silas::Slack.verify_signature delegation" do
    let(:now) { 1_700_000_000 }
    let(:slack_signature) do
      "v0=" + OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{now}:#{body}")
    end

    it "accepts a genuine Slack request" do
      expect(Silas::Slack.verify_signature(signing_secret: secret, timestamp: now,
                                           body: body, signature: slack_signature, now: now)).to be(true)
    end

    it "refuses a Slack request with no timestamp (Slack always sends one)" do
      expect(Silas::Slack.verify_signature(signing_secret: secret, timestamp: nil,
                                           body: body, signature: slack_signature, now: now)).to be(false)
    end

    it "refuses a stale Slack request" do
      expect(Silas::Slack.verify_signature(signing_secret: secret, timestamp: now,
                                           body: body, signature: slack_signature, now: now + 301)).to be(false)
    end
  end
end
