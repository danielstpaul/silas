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

    # Where the host mounted the engine ("/silas" by the installer's
    # convention), discovered from the app's route set. Used to build paths
    # that work in EVERY render context — including Turbo's bare broadcast
    # renderer, which has no routing scope for the mounted proxy to lean on.
    def mount_path
      @mount_path ||= begin
        route = Rails.application.routes.routes.find do |r|
          r.app.respond_to?(:app) && r.app.app == Silas::Engine
        end
        route&.path&.spec.to_s.sub(/\(.*\z/, "").presence || "/silas"
      end
    end

    def reset_mount_path! = (@mount_path = nil) # specs remount
  end
end
