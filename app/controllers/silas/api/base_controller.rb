module Silas
  module Api
    # JSON API base: ActionController::API (no CSRF, no layouts, no cookies),
    # deny-by-default auth with the inbox's contract — the host lambda DENIES
    # by rendering (or head-ing) and PASSES by not rendering.
    class BaseController < ActionController::API
      before_action :authenticate!

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "not found" }, status: :not_found
      end

      private

      def authenticate!
        Silas.config.api_auth.call(self)
      end

      def current_actor
        Silas.config.api_actor.call(self)
      end
    end
  end
end
