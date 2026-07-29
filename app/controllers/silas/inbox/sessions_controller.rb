module Silas
  module Inbox
    class SessionsController < BaseController
      before_action :authenticate_write!, only: :create

      PER_PAGE = 50

      def index
        # Keyset pagination on id (?before=<id> pages older), newest first.
        scope = Silas::Session.order(id: :desc)
        scope = scope.where(agent_name: params[:agent]) if params[:agent].present?
        if params[:pending].present? # the "N awaiting approval" badge drills into this
          # Subquery, not joins+distinct: DISTINCT over silas_sessions.* trips
          # on the json metadata column (PG json has no equality operator).
          scope = scope.where(
            id: Silas::Turn.joins(:tool_invocations)
                           .where(silas_tool_invocations: { approval_state: "required" })
                           .select(:session_id)
          )
        end
        scope = scope.where(id: ...params[:before].to_i) if params[:before].present?

        # One query for the rows + turns, one for the pending counts — the
        # per-row active_turn/turns.last/counts pattern was ~4 queries a card.
        # parent_session rides along for the lineage line: every child row
        # names the agent that handed to it, and that must not cost a query.
        @sessions = scope.limit(PER_PAGE).includes(:turns, :parent_session).to_a
        @next_before = @sessions.last&.id if @sessions.size == PER_PAGE
        @pending_counts = Silas::ToolInvocation.joins(:turn)
                                               .where(approval_state: "required",
                                                      silas_turns: { session_id: @sessions.map(&:id) })
                                               .group("silas_turns.session_id").count
        @agent_names = Silas::Session.distinct.pluck(:agent_name).sort
        @pending_total = Silas::ToolInvocation.where(approval_state: "required").count
      end

      def show
        @session = Silas::Session.find(params[:id])
        @turns = @session.turns.includes(steps: :tool_invocations)
        @cost = Silas::Inbox::Cost.for_session(@session)
      end

      # Start a session from the browser. channel stays nil ("direct") — web
      # chat is read live on the session page, not delivered outbound.
      def create
        input = params[:input].to_s.strip
        return redirect_to inbox_sessions_path, alert: "Type a message first." if input.empty?

        handle = params[:agent].present? ? Silas.agent(params[:agent]) : Silas.agent
        started = handle.start(input: input)
        redirect_to inbox_session_path(started)
      rescue Silas::Error => e
        redirect_to inbox_sessions_path, alert: e.message
      end
    end
  end
end
