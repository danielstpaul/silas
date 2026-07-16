module Silas
  module Channels
    class BaseController < ActionController::Base
      skip_forgery_protection # webhooks are authenticated by signature/token, not CSRF

      private

      # Reject anything not genuinely signed by Slack (or with a stale timestamp).
      def verify_slack!
        secret = Silas.config.slack_signing_secret
        ok = Silas::Slack.verify_signature(
          signing_secret: secret,
          timestamp: request.headers["X-Slack-Request-Timestamp"],
          body: request.raw_post,
          signature: request.headers["X-Slack-Signature"]
        )
        head(:unauthorized) unless ok
        ok
      end
    end
  end
end
