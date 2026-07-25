module Silas
  class ToolInvocation < ApplicationRecord
    STATUSES = %w[pending started completed failed in_doubt].freeze
    EFFECT_MODES = %w[transactional at_most_once idempotent].freeze
    APPROVAL_STATES = [ nil, "required", "approved", "answered", "declined", "expired" ].freeze

    include Silas::Inbox::Broadcastable

    belongs_to :step, class_name: "Silas::Step", inverse_of: :tool_invocations
    belongs_to :turn, class_name: "Silas::Turn", inverse_of: :tool_invocations

    validates :status, inclusion: { in: STATUSES }
    validates :effect_mode, inclusion: { in: EFFECT_MODES }
    validates :approval_state, inclusion: { in: APPROVAL_STATES }
    validates :tool_call_id, :tool_name, presence: true

    def completed? = status == "completed"
    def in_doubt?  = status == "in_doubt"
    def awaiting_approval? = approval_state == "required"

    # A parked ask_question — same park, different verdict: it is ANSWERED
    # (free text becomes the tool result), never approved into execution.
    def question? = tool_name == "ask_question"

    # Outbound: when a channel-bound invocation parks for approval, ping the
    # channel off-loop (covers both approval-gate and in-doubt parking).
    after_update_commit :notify_channel_approval, if: :should_notify_approval?

    def should_notify_approval?
      saved_change_to_approval_state? && approval_state == "required" && turn.session.channel.present?
    end

    def notify_channel_approval
      ChannelDeliveryJob.perform_later("approval", id)
    end

    # Approve a parked invocation and resume the turn with a FRESH job (the
    # parked job exited normally; its continuation is consumed). For an
    # in-doubt invocation, approval means "it did not run — re-execute".
    def approve!(by: nil)
      if question?
        raise Error, "invocation #{id} is a question — settle it with answer!, not approve! " \
                     "(approving would try to EXECUTE ask_question, which has no execution)"
      end
      assert_parked!
      assert_turn_resumable!
      update!(status: "pending", approval_state: "approved", approved_by: by)
      Silas.instrument(:approval, action: "approved", tool: tool_name, by: by,
                                  invocation_id: id, turn_id: turn_id)
      resume_turn!
    end

    # Answer a parked question. The text IS the tool result — the model resumes
    # with {"answer" => text}, persisted like any other settled invocation, so
    # replay determinism costs nothing. (decline! also works on a question: a
    # refusal to answer, delivered as {"denied" => reason}.)
    def answer!(text:, by: nil)
      raise Error, "invocation #{id} (#{tool_name}) is not a question — answer! settles ask_question only" unless question?
      raise Error, "an answer cannot be blank — decline! is the way to refuse a question" if text.blank?

      assert_parked!
      assert_turn_resumable!
      update!(status: "completed", approval_state: "answered", approved_by: by,
              result: { "answer" => text })
      Silas.instrument(:approval, action: "answered", tool: tool_name, by: by,
                                  invocation_id: id, turn_id: turn_id)
      resume_turn!
    end

    # Decline: for an approval gate, eve's shape — the tool is not executed
    # and the model sees {denied: reason} as the result, then the loop
    # continues. For an in-doubt invocation, decline means "assume it ran /
    # abandon" — the operator-supplied reason becomes the recorded outcome.
    def decline!(reason:, by: nil)
      assert_parked!
      assert_turn_resumable!
      update!(status: "failed", approval_state: "declined", approved_by: by,
              decline_reason: reason, result: { "denied" => reason })
      Silas.instrument(:approval, action: "declined", tool: tool_name, by: by,
                                  invocation_id: id, turn_id: turn_id)
      resume_turn!
    end

    # Sweep for the rescuer: expire parked invocations past their TTL and fail
    # their turns (parked-forever ghosts are a bug, not a feature).
    def self.expire_stale!(now: Time.current)
      where(approval_state: "required").where(approval_expires_at: ..now).find_each do |inv|
        result = inv.question? ? { "answer" => nil, "note" => "question expired unanswered" }
                               : { "denied" => "approval expired" }
        inv.update!(approval_state: "expired", status: "failed", result: result)
        Silas.instrument(:approval, action: "expired", tool: inv.tool_name,
                                    invocation_id: inv.id, turn_id: inv.turn_id)
        inv.turn.finish!(:failed, reason: "approval_expired")
      end
    end

    private

    def assert_parked!
      return if awaiting_approval?

      raise Error, "invocation #{id} is not awaiting approval (state: #{approval_state.inspect})"
    end

    # A failed turn must never be zombie-resumed by a stale approval card:
    # force-fail paths expire approvals first, but a card already rendered in
    # someone's browser can still POST — the verdict must land on a live turn.
    def assert_turn_resumable!
      return unless turn.reload.failed?

      raise Error, "turn #{turn.id} already failed (#{turn.failure_reason}) — " \
                   "this approval can no longer resume it"
    end

    def resume_turn!
      return if turn.reload.canceled? || turn.failed? # settled turns never zombie-resume
      return if turn.tool_invocations.where(approval_state: "required").exists?

      # Restart the wall clock: `limits.timeout` bounds ACTIVE stretches (hung
      # providers, runaway loops), not human deliberation. Without this, any
      # approval that took longer than the timeout made the approved resume
      # instantly re-park on "timeout" — pathological for a gate whose whole
      # point is waiting for a person. Cost/token budgets stay cumulative;
      # they measure real spend.
      parked_for = turn.updated_at ? (Time.current - turn.updated_at).to_f : nil
      turn.update!(status: "queued", started_at: Time.current)
      Silas.instrument(:resume, turn_id: turn.id, parked_for: parked_for)
      AgentLoopJob.perform_later(turn.id)
    end
  end
end
