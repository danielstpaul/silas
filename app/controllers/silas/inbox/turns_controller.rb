module Silas
  module Inbox
    # The web composer: append a turn to an existing session. Same write-auth
    # gate as approve/decline. Deliberately thin — the turn runs on the durable
    # loop and the model's after_commit broadcasts render it live, so this
    # controller only enqueues and redirects.
    class TurnsController < BaseController
      before_action :authenticate_write!

      def create
        agent_session = Silas::Session.find(params[:session_id])
        input = params[:input].to_s.strip
        return redirect_to inbox_session_path(agent_session), alert: "Type a message first." if input.empty?

        agent_session.continue(input: input)
        redirect_to inbox_session_path(agent_session)
      rescue Silas::TurnInProgressError
        redirect_to inbox_session_path(agent_session), alert: "A turn is already running — wait for it to settle."
      end

      # Cancel from the trace. Running turns are flagged and honored at the
      # next step boundary (the same safe point as budgets); parked/queued
      # turns cancel immediately.
      def cancel
        turn = Silas::Turn.find(params[:id])
        outcome = turn.cancel!(reason: "canceled from inbox by #{current_actor}")
        notice = outcome == :cancel_requested ? "Cancel requested — honored at the next step boundary." : "Turn canceled."
        redirect_to inbox_session_path(turn.session_id), notice: notice
      end
    end
  end
end
