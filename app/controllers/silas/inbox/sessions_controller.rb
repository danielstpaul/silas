module Silas
  module Inbox
    class SessionsController < BaseController
      def index
        @sessions = Silas::Session.order(created_at: :desc).limit(100)
        @sessions = @sessions.where(agent_name: params[:agent]) if params[:agent].present?
        @agent_names = Silas::Session.distinct.pluck(:agent_name).sort
        @pending_total = Silas::ToolInvocation.where(approval_state: "required").count
      end

      def show
        @session = Silas::Session.find(params[:id])
        @turns = @session.turns.includes(steps: :tool_invocations)
        @cost = Silas::Inbox::Cost.for_session(@session)
      end
    end
  end
end
