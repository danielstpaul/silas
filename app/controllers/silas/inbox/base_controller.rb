module Silas
  module Inbox
    # Deny-by-default (lifted from ruby_llm-resilience's dashboard_auth): the
    # host's inbox_auth lambda renders/head-404s to DENY and passes by NOT
    # rendering. A fresh mount is invisible until the host opts in.
    class BaseController < ActionController::Base
      protect_from_forgery with: :exception
      layout "silas/inbox"

      before_action :authenticate_read!

      helper Silas::Inbox::TraceHelper

      private

      # Reads: allowed in public-read mode, else the host lambda must pass.
      def authenticate_read!
        return if Silas.config.inbox_public_read

        deny_unless_authed!
      end

      # Writes (approve/decline): ALWAYS the host lambda, even in public-read.
      def authenticate_write!
        deny_unless_authed!
      end

      def deny_unless_authed!
        Silas.config.inbox_auth.call(self)
      end

      def current_actor
        Silas.config.inbox_actor.call(self)
      end
    end
  end
end
