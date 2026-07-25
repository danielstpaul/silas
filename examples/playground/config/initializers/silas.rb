Silas.configure do |config|
  # With a key: the real model via RubyLLM. Without one: a scripted stand-in
  # (lib/demo_engine.rb) so `bin/setup && bin/dev` needs zero secrets — the
  # tools, ledger, approvals, and streaming are all still real.
  if ENV["ANTHROPIC_API_KEY"].present?
    config.adapter = :ruby_llm
  else
    require Rails.root.join("lib/demo_engine").to_s
    config.adapter = DemoEngine.new
  end
  config.default_model = "claude-sonnet-4-5"

  # THIS IS A DEMO. The operator inbox is readable by anyone so you can watch
  # the trace, the cost, and the audit trail from the other side of the glass
  # — but approve/decline still require the write lambda below, because a
  # visitor must not be able to release someone else's £48 refund.
  #
  # In a real app you would delete `inbox_public_read` and gate reads too:
  #   config.inbox_auth = ->(c) { c.head :not_found unless c.current_user&.admin? }
  config.inbox_public_read = true

  # Write access (approve/decline, cancel, budget top-up) — off unless the
  # operator password is set. `PLAYGROUND_OPERATOR_PASSWORD=... bin/dev` and
  # the inbox will ask for it.
  config.inbox_auth = lambda do |controller|
    expected = ENV["PLAYGROUND_OPERATOR_PASSWORD"]
    if expected.blank?
      controller.head :forbidden
    else
      controller.request_http_basic_authentication("Tinker & Co operators") unless
        controller.send(:authenticate_with_http_basic) { |_u, p| ActiveSupport::SecurityUtils.secure_compare(p.to_s, expected) }
    end
  end

  config.inbox_actor = ->(_controller) { "operator" }

  # The JSON API stays fully closed on the public demo — it can start sessions
  # and approve money movements. Set an API token to open it.
  config.api_auth = lambda do |controller|
    token = ENV["PLAYGROUND_API_TOKEN"]
    if token.blank?
      controller.head :not_found
    else
      presented = controller.request.headers["Authorization"].to_s.delete_prefix("Bearer ")
      controller.head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(presented, token)
    end
  end
end
