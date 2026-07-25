require "net/http"
require "json"
require "openssl"

module Silas
  # Thin Slack Web API helper — no gem dependency. Posting (chat.postMessage),
  # approval Block Kit, and inbound request-signature verification.
  module Slack
    module_function

    POST_MESSAGE = "https://slack.com/api/chat.postMessage".freeze
    REPLAY_WINDOW = 300 # seconds

    def post_message(channel:, text:, blocks: nil, thread_ts: nil, token: Silas.config.slack_bot_token)
      raise Error, "no Slack bot token configured (credentials.silas.slack.bot_token)" if token.blank?

      body = { channel: channel, text: text }
      body[:blocks] = blocks if blocks
      body[:thread_ts] = thread_ts if thread_ts

      res = Net::HTTP.post(URI(POST_MESSAGE), body.to_json,
                           "content-type" => "application/json; charset=utf-8",
                           "authorization" => "Bearer #{token}")
      JSON.parse(res.body)
    end

    # Approve/Decline buttons; the button value is the invocation id, so the
    # actions webhook maps a click straight to invocation.approve!/decline!.
    def approval_blocks(invocation)
      [
        { "type" => "section",
          "text" => { "type" => "mrkdwn",
                      "text" => "*Approval needed:* `#{invocation.tool_name}`\n```#{JSON.generate(invocation.arguments)}```" } },
        { "type" => "actions", "block_id" => "silas_approval",
          "elements" => [
            { "type" => "button", "action_id" => "silas_approve", "style" => "primary",
              "text" => { "type" => "plain_text", "text" => "Approve" }, "value" => invocation.id.to_s },
            { "type" => "button", "action_id" => "silas_decline", "style" => "danger",
              "text" => { "type" => "plain_text", "text" => "Decline" }, "value" => invocation.id.to_s }
          ] }
      ]
    end

    # Slack signs each request (v0 scheme) — HMAC-SHA256 over "v0:ts:body" plus a
    # 5-minute replay window. Returns true only for a genuine, fresh request.
    # Slack ALWAYS sends a timestamp, so a missing one is refused here rather
    # than falling through to Webhook's "no timestamp, no window" default.
    def verify_signature(signing_secret:, timestamp:, body:, signature:, now: Time.current.to_i)
      return false if timestamp.blank?

      Silas::Webhook.verify_hmac(
        secret: signing_secret, signature: signature,
        payload: "v0:#{timestamp}:#{body}", timestamp: timestamp,
        window: REPLAY_WINDOW, prefix: "v0=", now: now
      )
    end
  end
end
