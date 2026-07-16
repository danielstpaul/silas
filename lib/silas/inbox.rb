module Silas
  # The mountable inbox UI (at /silas/inbox). It renders the existing rows
  # (Session -> Turn -> Step -> ToolInvocation) as a live trace — no events
  # table — and streams changes over Turbo when the host has turbo-rails.
  module Inbox
    module_function

    # turbo-rails is NOT a gem dependency (the core stays lean, like the
    # solid_queue guard). Broadcasting activates only when the host bundles it.
    def streaming_available?
      defined?(Turbo::StreamsChannel)
    end

    # Broadcasting is on when Turbo is present. A host can hard-disable it.
    def streaming?
      streaming_available? && Silas.config.inbox_streaming != false
    end

    def stream_name(session_id)
      "silas:inbox:session:#{session_id}"
    end
  end
end
