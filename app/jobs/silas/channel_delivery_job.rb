module Silas
  # Outbound delivery, decoupled from the durable loop. Triggered by after_commit
  # callbacks on Turn/ToolInvocation; idempotent via a CAS claim on the marker
  # column (notified_at/answered_at), released if the send raises so a retry can
  # re-attempt. Duplicate pings are the worst failure — never a ledger violation
  # (approve!/decline! are idempotent).
  class ChannelDeliveryJob < ActiveJob::Base
    queue_as { Silas.config.queue_name }

    def perform(kind, id)
      case kind
      when "approval" then deliver_approval(id)
      when "answer"   then deliver_answer(id)
      end
    end

    private

    def deliver_approval(id)
      invocation = ToolInvocation.find_by(id: id)
      return unless invocation&.approval_state == "required"
      return unless claim!(ToolInvocation, invocation.id, :notified_at)

      channel = Channel.for_session(invocation.turn.session)
      return release!(ToolInvocation, invocation.id, :notified_at) unless channel

      with_release(ToolInvocation, invocation.id, :notified_at) do
        channel.deliver_approval(session: invocation.turn.session, invocation: invocation)
      end
    end

    def deliver_answer(id)
      turn = Turn.find_by(id: id)
      return unless turn && (turn.completed? || turn.status == "failed")
      return unless claim!(Turn, turn.id, :answered_at)

      channel = Channel.for_session(turn.session)
      return release!(Turn, turn.id, :answered_at) unless channel

      with_release(Turn, turn.id, :answered_at) do
        channel.deliver_answer(session: turn.session, text: turn.answer_text)
      end
    end

    # Compare-and-swap: only the execution that flips NULL -> now proceeds.
    def claim!(model, id, column)
      model.where(id: id, column => nil).update_all(column => Time.current) == 1
    end

    def release!(model, id, column)
      model.where(id: id).update_all(column => nil)
      false
    end

    def with_release(model, id, column)
      yield
    rescue StandardError
      release!(model, id, column) # send failed — free the claim for a retry
      raise
    end
  end
end
