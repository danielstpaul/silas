module Silas
  module Inbox
    # Streams accumulated step text into the live trace as it arrives.
    #
    # Synchronous on purpose: broadcast_update_to, not _later — the row
    # broadcasts ride ActiveJob because they are rare; a delta batch every
    # ~100ms per running turn would swamp the queue. The push happens on the
    # worker thread mid-model-call, so it is wrapped: a cable/render failure
    # can NEVER re-raise into the durable loop.
    #
    # Deltas are decoration. The authoritative after_commit row render replaces
    # the whole step partial (dom_id target) and supersedes anything streamed
    # into the inner text container.
    module DeltaBroadcaster
      EVENT = "delta.silas".freeze

      class << self
        def subscribe!
          @subscription ||= ActiveSupport::Notifications.subscribe(EVENT) do |*args|
            broadcast(args.last)
          end
        end

        def broadcast(payload)
          return unless Silas::Inbox.streaming?

          Turbo::StreamsChannel.broadcast_update_to(
            Silas::Inbox.stream_name(payload[:session_id]),
            target: "silas-step-#{payload[:step_id]}-text",
            html: ERB::Util.html_escape(payload[:text]) # plain text; the row render owns formatting
          )
        rescue StandardError => e
          Rails.logger&.warn("[silas.inbox] delta broadcast failed: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
