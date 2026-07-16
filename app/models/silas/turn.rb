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
    def active?    = ACTIVE_STATUSES.include?(status)
    def parked?    = status == "waiting" || status == "in_doubt"

    def finish!(new_status, reason: nil)
      update!(status: new_status.to_s, failure_reason: reason, finished_at: Time.current)
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
