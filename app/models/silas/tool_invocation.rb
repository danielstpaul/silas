module Silas
  class ToolInvocation < ApplicationRecord
    STATUSES = %w[pending started completed failed in_doubt].freeze
    EFFECT_MODES = %w[transactional at_most_once idempotent].freeze
    APPROVAL_STATES = [ nil, "required", "approved", "declined", "expired" ].freeze

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
      assert_parked!
      update!(status: "pending", approval_state: "approved", approved_by: by)
      resume_turn!
    end

    # Decline: for an approval gate, eve's shape — the tool is not executed
    # and the model sees {denied: reason} as the result, then the loop
    # continues. For an in-doubt invocation, decline means "assume it ran /
    # abandon" — the operator-supplied reason becomes the recorded outcome.
    def decline!(reason:, by: nil)
      assert_parked!
      update!(status: "failed", approval_state: "declined", approved_by: by,
              decline_reason: reason, result: { "denied" => reason })
      resume_turn!
    end

    # Sweep for the rescuer: expire parked invocations past their TTL and fail
    # their turns (parked-forever ghosts are a bug, not a feature).
    def self.expire_stale!(now: Time.current)
      where(approval_state: "required").where(approval_expires_at: ..now).find_each do |inv|
        inv.update!(approval_state: "expired", status: "failed",
                    result: { "denied" => "approval expired" })
        inv.turn.finish!(:failed, reason: "approval_expired")
      end
    end

    private

    def assert_parked!
      return if awaiting_approval?

      raise Error, "invocation #{id} is not awaiting approval (state: #{approval_state.inspect})"
    end

    def resume_turn!
      return if turn.tool_invocations.where(approval_state: "required").exists?

      turn.update!(status: "queued")
      AgentLoopJob.perform_later(turn.id)
    end
  end
end
