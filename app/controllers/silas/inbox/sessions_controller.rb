module Silas
  module Inbox
    class SessionsController < BaseController
      def index
        @sessions = Silas::Session.order(created_at: :desc).limit(100)
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
