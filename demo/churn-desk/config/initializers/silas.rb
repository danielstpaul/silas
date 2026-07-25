Silas.configure do |config|
  config.engine = :ruby_llm
  config.inbox_public_read = true

  # DEMO ONLY — let anyone on this local server approve/decline. Deny-by-default
  # in production: gate on your own auth, e.g.
  #   config.inbox_auth = ->(ctrl) { ctrl.head :not_found unless ctrl.current_user&.admin? }
  config.inbox_auth = ->(_controller) { }

  # Demo: one execution per turn, no re-enqueue between steps. Pairs with the
  # :inline adapter set below. Production leaves this at its default (true).
  config.isolate_steps = false
end

# DEMO ONLY — run turns synchronously in one process. Rails' dev-default Async
# adapter double-executes steps and breaks exactly-once (Silas warns at boot).
# The kill-the-server durability recording uses Solid Queue instead — see README.
ActiveJob::Base.queue_adapter = :inline
