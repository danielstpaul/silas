module Silas
  module Inbox
    # Approve/decline from the UI — the SAME code path as the Slack buttons and
    # email links (invocation.approve!/decline!). Writes always require real
    # auth, even when reads are public.
    class InvocationsController < BaseController
      before_action :authenticate_write!
      before_action :set_invocation

      def approve
        @invocation.approve!(by: current_actor)
        respond_resolved
      rescue Silas::Error => e
        respond_error(e)
      end

      def decline
        # decline-with-note: the textarea's reason becomes {denied: reason},
        # which the model sees as the tool result.
        reason = params[:reason].presence || "declined from inbox"
        @invocation.decline!(reason: reason, by: current_actor)
        respond_resolved
      rescue Silas::Error => e
        respond_error(e)
      end

      private

      def set_invocation
        @invocation = Silas::ToolInvocation.find(params[:id])
      end

      def respond_resolved
        # The model's own after_commit broadcast fans the update to every open
        # trace; this response just returns the caller to the session.
        redirect_to inbox_session_path(@invocation.turn.session_id)
      end

      def respond_error(error)
        redirect_to inbox_session_path(@invocation.turn.session_id), alert: error.message
      end
    end
  end
end
