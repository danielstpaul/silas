module Silas
  class Turn < ApplicationRecord
    STATUSES = %w[queued running waiting in_doubt completed failed canceled].freeze
    ACTIVE_STATUSES = %w[queued running waiting in_doubt].freeze

    include Silas::Inbox::Broadcastable

    belongs_to :session, class_name: "Silas::Session", inverse_of: :turns
    has_many :steps, -> { order(:index) }, class_name: "Silas::Step", foreign_key: :turn_id,
             inverse_of: :turn, dependent: :destroy
    has_many :tool_invocations, class_name: "Silas::ToolInvocation", foreign_key: :turn_id,
             inverse_of: :turn, dependent: :destroy

    validates :status, inclusion: { in: STATUSES }
    validates :index, presence: true
    validate :instructions_snapshot_immutable, on: :update

    ACTIVE_STATUSES.each { |s| define_method(:"#{s}?") { status == s } }
    def completed? = status == "completed"
    def failed?    = status == "failed"
    def active?    = ACTIVE_STATUSES.include?(status)
    def parked?    = status == "waiting" || status == "in_doubt"

    def finish!(new_status, reason: nil)
      update!(status: new_status.to_s, failure_reason: reason, finished_at: Time.current)
    end

    def canceled? = status == "canceled"

    # Cancel a turn. A PARKED or QUEUED turn (no live execution) settles to
    # canceled immediately, expiring its pending approvals so a later approve!
    # can't zombie-resume it. A RUNNING turn is flagged; the loop honors the
    # flag at the next step boundary — the in-flight model call completes and
    # its step commits (aborting mid-step would forfeit paid work and create
    # an in-doubt tool window for nothing).
    def cancel!(reason: "canceled")
      raise Error, "turn #{id} is already terminal (#{status})" unless active?

      if running?
        update!(cancel_requested_at: Time.current)
        :cancel_requested
      else
        expire_pending_approvals!(reason)
        finish!(:canceled, reason: reason)
        :canceled
      end
    end

    def expire_pending_approvals!(reason)
      tool_invocations.where(approval_state: "required").find_each do |inv|
        inv.update!(approval_state: "expired", status: "failed",
                    result: { "denied" => reason })
      end
    end

    # Parked by a budget cap (failure_reason doubles as the park reason while
    # the turn is waiting; it is cleared on resume).
    def budget_parked?
      waiting? && Budget::REASONS.include?(failure_reason)
    end

    # Human top-up for a budget-parked turn: record the raised limit(s) and
    # resume with a fresh job — completed steps replay from rows, no model
    # re-calls, no re-effects (the same resume path approvals use).
    #   turn.raise_budget!(max_cost: 1.50)          # dollars
    #   turn.raise_budget!(max_input_tokens: 200_000, timeout: 3600)
    def raise_budget!(max_cost: nil, max_input_tokens: nil, timeout: nil)
      raise Error, "turn #{id} is not budget-parked (#{status}/#{failure_reason})" unless budget_parked?

      raises = { "max_cost" => max_cost, "max_input_tokens" => max_input_tokens,
                 "timeout" => timeout }.compact
      raise ArgumentError, "pass at least one limit to raise" if raises.empty?

      update!(budget_overrides: (budget_overrides || {}).merge(raises),
              failure_reason: nil, status: "queued")
      AgentLoopJob.perform_later(id)
    end

    # The agent's answer for this turn: the last completed step's text blocks.
    def answer_text
      step = steps.where(status: "completed").order(:index).last
      return "" unless step

      Array(step.response_blocks).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    end

    # Outbound: when a channel-bound turn reaches an answer, deliver it off-loop.
    after_update_commit :notify_channel_answer, if: :should_notify_answer?

    private

    def should_notify_answer?
      saved_change_to_status? && (completed? || status == "failed") && session.channel.present?
    end

    def notify_channel_answer
      ChannelDeliveryJob.perform_later("answer", id)
    end

    private

    # The snapshot is the determinism anchor for the whole turn: once rendered
    # at :prepare it must never change (a resumed job re-reads it).
    def instructions_snapshot_immutable
      return unless instructions_snapshot_changed? && instructions_snapshot_was.present?

      errors.add(:instructions_snapshot, "is immutable once set")
    end
  end
end
