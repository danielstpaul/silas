module Silas
  # The mounted MCP endpoint: POST /silas/mcp, JSON-RPC over plain
  # request/response (the Streamable HTTP transport's stateless mode — each
  # POST answered with application/json, no SSE stream). Deny-by-default auth
  # with the same host-lambda contract as the JSON API: the lambda DENIES by
  # rendering (or head-ing) and PASSES by not rendering. An MCP client is a
  # machine, so the natural pass is a bearer check:
  #
  #   config.mcp_auth = lambda do |controller|
  #     supplied = controller.request.headers["Authorization"].to_s
  #     expected = "Bearer #{Rails.application.credentials.dig(:silas, :mcp_token)}"
  #     controller.head :unauthorized unless
  #       ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
  #   end
  class McpController < ActionController::API
    before_action :authenticate!

    def handle
      status, body = Silas::Mcp::Handler.new.call(body: request.raw_post)
      if body
        render json: body, status: status
      else
        head status
      end
    end

    private

    def authenticate!
      Silas.config.mcp_auth.call(self)
    end
  end
end
