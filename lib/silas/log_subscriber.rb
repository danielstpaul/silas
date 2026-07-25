require "active_support/log_subscriber"

# Turns the loop's notifications into log lines, at levels that match what an
# operator actually wants paged about: parks and rescues are INFO (a human is
# now in the loop, or a crash was recovered), budget breaches and
# nondeterminism are WARN, failed turns are ERROR, and the per-step/per-token
# chatter stays DEBUG.
#
# Attach is automatic (see Silas::Engine). To silence just Silas:
#   Silas.logger = Logger.new(IO::NULL)
class Silas::LogSubscriber < ActiveSupport::LogSubscriber
  def turn(event)
    status = event.payload[:status]
    line = formatted_event(event, action: "Turn #{status}",
                           **event.payload.slice(:turn_id, :session_id, :agent, :steps, :reason).compact)
    status.to_s == "failed" ? error(line) : info(line)
  end

  def step(event)
    debug formatted_event(event, action: "Model call",
                          **event.payload.slice(:turn_id, :index, :model).compact)
  end

  def tool(event)
    line = formatted_event(event, action: "Tool #{event.payload[:tool]}",
                           **event.payload.slice(:effect_mode, :status, :approval_state, :turn_id).compact)
    event.payload[:status].to_s == "failed" ? warn(line) : info(line)
  end

  def park(event)
    info formatted_event(event, action: "Turn parked (#{event.payload[:reason]})",
                         **event.payload.slice(:turn_id, :detail).compact)
  end

  def resume(event)
    parked_for = event.payload[:parked_for]
    info formatted_event(event, action: "Turn resumed after #{parked_for&.round(1)}s parked",
                         **event.payload.slice(:turn_id).compact)
  end

  def approval(event)
    info formatted_event(event, action: "Approval #{event.payload[:action]}",
                         **event.payload.slice(:tool, :by, :turn_id).compact)
  end

  def budget(event)
    warn formatted_event(event, action: "Budget reached (#{event.payload[:reason]})",
                         **event.payload.slice(:turn_id).compact)
  end

  def nondeterminism(event)
    error formatted_event(event, action: "Definitions changed mid-turn",
                          **event.payload.slice(:turn_id, :was, :now).compact)
  end

  def rescue(event)
    payload = event.payload
    return if payload[:rescued].to_i.zero? && payload[:stranded].to_i.zero?

    info formatted_event(event, action: "Rescuer", **payload.slice(:rescued, :stranded))
  end

  # delta.silas is deliberately NOT logged — it fires many times per second
  # per running turn. Subscribe to it directly if you want the firehose.

  private
    def formatted_event(event, action:, **attributes)
      "Silas-#{Silas::VERSION} #{action} (#{event.duration.round(1)}ms)  #{formatted_attributes(**attributes)}"
    end

    def formatted_attributes(**attributes)
      attributes.map { |attr, value| "#{attr}: #{value.inspect}" }.join(", ")
    end

    def logger
      Silas.logger
    end
end
