module Silas
  class Step < ApplicationRecord
    STATUSES = %w[started completed].freeze

    include Silas::Inbox::Broadcastable

    belongs_to :turn, class_name: "Silas::Turn", inverse_of: :steps
    has_many :tool_invocations, class_name: "Silas::ToolInvocation", foreign_key: :step_id,
             inverse_of: :step, dependent: :destroy

    validates :status, inclusion: { in: STATUSES }
    validates :index, presence: true
    validate :terminal_write_once, on: :update

    def completed? = status == "completed"

    # Any invocation awaiting a human: approval-gated or in-doubt.
    def parked?
      tool_invocations.any? { |i| i.approval_state == "required" || i.status == "in_doubt" }
    end

    private

    # THE loop-control column (spike finding #3 generalized): a resumed
    # continuation re-derives its step sequence from terminal, so it must be
    # write-once. NULL -> value is the only legal transition.
    def terminal_write_once
      return unless terminal_changed? && !terminal_was.nil?

      errors.add(:terminal, "is write-once")
    end
  end
end
