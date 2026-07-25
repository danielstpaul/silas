require "openssl"

module Silas
  # Inbound webhook signature verification, shared by every channel.
  #
  # Vendors differ only in what they sign and how they label it: Slack signs
  # "v0:#{timestamp}:#{body}" and prefixes "v0=", GitHub signs the raw body and
  # prefixes "sha256=", Shopify signs the raw body and Base64-encodes it. The
  # dangerous parts are identical everywhere — constant-time comparison, a
  # replay window, and failing closed on a missing secret — so they live here
  # and get tested once, while the caller supplies the vendor's shape.
  module Webhook
    module_function

    REPLAY_WINDOW = 300 # seconds

    # Returns true ONLY for a genuine, fresh request. Every failure path returns
    # false rather than raising: a webhook endpoint answers 401, it does not 500.
    #
    #   secret      the shared signing secret. Blank => false (a channel with no
    #               secret configured must reject, never accept).
    #   signature   the header value, exactly as sent.
    #   payload     the bytes the vendor signed — usually request.raw_post,
    #               sometimes a basestring built from it. NEVER the parsed
    #               params: re-serializing changes the bytes and the HMAC.
    #   timestamp   the vendor's request timestamp, if it sends one. Present =>
    #               anything outside +/- window is refused as a replay.
    #   prefix      whatever the vendor puts before the digest ("v0=", "sha256=").
    #   digest      "hex" (nearly everyone) or "base64" (Shopify, Twilio).
    def verify_hmac(secret:, signature:, payload:, timestamp: nil, window: REPLAY_WINDOW,
                    prefix: "", algorithm: "SHA256", digest: :hex, now: Time.current.to_i)
      return false if secret.blank? || signature.blank?
      return false if timestamp.present? && window && (now - timestamp.to_i).abs > window

      expected = prefix + hmac(algorithm, secret, payload, digest)
      ActiveSupport::SecurityUtils.secure_compare(expected, signature)
    end

    def hmac(algorithm, secret, payload, digest)
      case digest
      when :hex    then OpenSSL::HMAC.hexdigest(algorithm, secret, payload)
      when :base64 then Base64.strict_encode64(OpenSSL::HMAC.digest(algorithm, secret, payload))
      else raise ArgumentError, "digest must be :hex or :base64, got #{digest.inspect}"
      end
    end
  end
end
