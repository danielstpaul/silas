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

        # Held is a QUERY, not a partition of the loaded page. The old
        # page-scoped partition meant a held session older than the newest 50
        # never appeared under Held while the global badge counted it — the
        # badge was right and the group was wrong. Held renders complete on
        # the first page; the keyset feed below it carries Working/Filed.
        @held_sessions = params[:before].present? ? [] : held_sessions_for(params[:agent])
        scope = scope.where.not(id: @held_sessions.map(&:id)) if @held_sessions.any?

        # One query for the rows + turns, one for the pending counts — the
        # per-row active_turn/turns.last/counts pattern was ~4 queries a card.
        # parent_session rides along for the lineage line: every child row
        # names the agent that handed to it, and that must not cost a query.
        @sessions = scope.limit(PER_PAGE).includes(:turns, :parent_session).to_a
        @next_before = @sessions.last&.id if @sessions.size == PER_PAGE
        @pending_counts = Silas::ToolInvocation.joins(:turn)
                                               .where(approval_state: "required",
                                                      silas_turns: { session_id: (@sessions + @held_sessions).map(&:id) })
                                               .group("silas_turns.session_id").count
        # The roster union: agents that exist on disk AND agents that exist
        # only as history. A configured agent with no sessions must be
        # filterable; a deleted-directory agent must be visible as history
        # rather than vanishing from its own audit trail.
        on_disk = [ "agent", *Silas.named_agent_scopes.keys ]
        historical = Silas::Session.distinct.pluck(:agent_name)
        @agent_names = (on_disk | historical).sort
        @orphaned_agents = (historical - on_disk).to_set
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

      private

      # A session is held when a person is needed: a pending approval or
      # question, or a turn parked waiting/in_doubt.
      def held_sessions_for(agent)
        scope = Silas::Session
                .where(id: Silas::Turn.where(status: %w[waiting in_doubt]).select(:session_id))
                .or(Silas::Session.where(id: Silas::Turn.joins(:tool_invocations)
                       .where(silas_tool_invocations: { approval_state: "required" })
                       .select(:session_id)))
        scope = scope.where(agent_name: agent) if agent.present?
        scope.order(id: :desc).limit(PER_PAGE).includes(:turns, :parent_session).to_a
      end
    end
  end
end
