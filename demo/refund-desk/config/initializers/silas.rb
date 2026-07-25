Silas.configure do |config|
  # Inference engine: :ruby_llm (API key, any provider RubyLLM supports).
  config.engine = :ruby_llm

  # Reads make anyone able to view the inbox trace on this local demo.
  config.inbox_public_read = true

  # DEMO ONLY — let anyone hitting this local server approve/decline. The write
  # gate is deny-by-default: the lambda DENIES by rendering (head :not_found)
  # and ALLOWS by returning without rendering. In production, gate on your auth:
  #   config.inbox_auth = ->(ctrl) { ctrl.head :not_found unless ctrl.current_user&.admin? }
  config.inbox_auth = ->(_controller) { }

  # Demo: run every step in one execution (no re-enqueue between steps). Pairs
  # with the :inline adapter set below. Production leaves this at its default
  # (true) so each step is a durable checkpoint.
  config.isolate_steps = false
end

# DEMO ONLY — run agent turns synchronously in this one process. Rails' dev
# default is the in-process Async adapter, which runs continuation retries on a
# thread pool CONCURRENTLY with the original job, double-executing steps and
# breaking exactly-once (Silas warns at boot if it sees Async). The synchronous
# :inline adapter is safe here — including the Approve → resume path, which
# enqueues via ActiveJob. Production uses Solid Queue (see silas/DEPLOY.md).
# Set on the class directly so it wins regardless of initializer load order.
ActiveJob::Base.queue_adapter = :inline
