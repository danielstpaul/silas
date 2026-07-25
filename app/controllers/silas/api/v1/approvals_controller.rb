module Silas
  module Api
    module V1
      # The headline feature over HTTP: list what's parked, approve or decline
      # it — the exact same approve!/decline! as the inbox, Slack, and email.
      class ApprovalsController < Silas::Api::BaseController
        include Silas::Api::Serialization

        # GET /silas/api/v1/sessions/:session_id/approvals
        def index
          session = Silas::Session.find(params[:session_id])
          render json: { approvals: session.pending_approvals.order(:id).map { |i| invocation_json(i) } }
        end

        # POST /silas/api/v1/approvals/:id/approve
        def approve
          invocation = Silas::ToolInvocation.find(params[:id])
          invocation.approve!(by: current_actor)
          render json: invocation_json(invocation.reload)
        rescue Silas::Error => e
          render json: { error: e.message }, status: :conflict
        end

        # POST /silas/api/v1/approvals/:id/decline  { reason: (optional) }
        def decline
          invocation = Silas::ToolInvocation.find(params[:id])
          invocation.decline!(reason: params[:reason].presence || "declined via api", by: current_actor)
          render json: invocation_json(invocation.reload)
        rescue Silas::Error => e
          render json: { error: e.message }, status: :conflict
        end

        # POST /silas/api/v1/approvals/:id/answer  { text: "..." }
        # ask_question's verdict: the text becomes the tool result.
        def answer
          invocation = Silas::ToolInvocation.find(params[:id])
          invocation.answer!(text: params[:text].to_s.strip, by: current_actor)
          render json: invocation_json(invocation.reload)
        rescue Silas::Error => e
          render json: { error: e.message }, status: :conflict
        end
      end
    end
  end
end
