module Silas
  module Inbox
    # Live trace: after_commit callbacks broadcast the changed row (rendered as
    # a partial) to the session's Turbo stream. Mirrors ChannelDeliveryJob's
    # after_commit -> off-loop decouple: the `_later` broadcasts render in
    # Turbo's own job, never on the durable loop, and every broadcast is wrapped
    # so a cable/render failure can NEVER roll back or slow a turn.
    #
    # Included in Turn/Step/ToolInvocation always; every callback early-returns
    # unless streaming is actually live, so headless hosts pay nothing.
    module Broadcastable
      extend ActiveSupport::Concern

      included do
        after_create_commit :silas_inbox_broadcast_create
        after_update_commit :silas_inbox_broadcast_update
      end

      private

      def silas_inbox_broadcast_create
        return unless Silas::Inbox.streaming?

        safe_broadcast do
          case self
          when Silas::Turn
            silas_inbox_dispatch(:append, session_id, target: "silas-turns",
                                 partial: "silas/inbox/turns/turn", locals: { turn: self })
          when Silas::Step
            silas_inbox_dispatch(:append, turn.session_id, target: "silas-turn-#{turn_id}-steps",
                                 partial: "silas/inbox/steps/step", locals: { step: self })
          when Silas::ToolInvocation
            silas_inbox_dispatch(:append, turn.session_id, target: "silas-step-#{step_id}-tools",
                                 partial: "silas/inbox/invocations/invocation", locals: { invocation: self })
          end
        end
      end

      def silas_inbox_broadcast_update
        return unless Silas::Inbox.streaming?

        safe_broadcast do
          case self
          when Silas::Turn
            next unless saved_change_to_status?

            silas_inbox_dispatch(:replace, session_id, target: "silas-turn-#{id}-header",
                                 partial: "silas/inbox/turns/header", locals: { turn: self })
          when Silas::Step
            next unless saved_change_to_status?

            silas_inbox_dispatch(:replace, turn.session_id, target: ActionView::RecordIdentifier.dom_id(self),
                                 partial: "silas/inbox/steps/step", locals: { step: self })
            silas_inbox_refresh_cost(turn.session)
          when Silas::ToolInvocation
            next unless saved_change_to_approval_state? || saved_change_to_status?

            silas_inbox_dispatch(:replace, turn.session_id, target: ActionView::RecordIdentifier.dom_id(self),
                                 partial: "silas/inbox/invocations/invocation", locals: { invocation: self })
          end
        end
      end

      def silas_inbox_refresh_cost(session)
        silas_inbox_dispatch(:replace, session.id, target: "silas-session-#{session.id}-cost",
                             partial: "silas/inbox/sessions/cost", locals: { session: session })
      end

      # The single seam over turbo-rails, so the dispatch logic above is
      # testable without loading turbo (stub this method).
      def silas_inbox_dispatch(action, session_id, target:, partial:, locals:)
        stream = Silas::Inbox.stream_name(session_id)
        case action
        when :append  then broadcast_append_later_to(stream, target: target, partial: partial, locals: locals)
        when :replace then broadcast_replace_later_to(stream, target: target, partial: partial, locals: locals)
        end
      end

      def safe_broadcast
        yield
      rescue StandardError => e
        Rails.logger&.warn("[silas.inbox] broadcast failed: #{e.class}: #{e.message}") # never re-raise into the loop
      end
    end
  end
end
