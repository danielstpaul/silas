module Silas
  class Session < ApplicationRecord
    STATUSES = %w[active archived].freeze

    has_many :turns, -> { order(:index) }, class_name: "Silas::Turn", foreign_key: :session_id,
             inverse_of: :session, dependent: :destroy

    validates :status, inclusion: { in: STATUSES }
    validates :agent_name, presence: true

    def active_turn
      # Fresh relation query, never the cached association — callers mix reads
      # with turn creation in the same objects.
      turns.where(status: Turn::ACTIVE_STATUSES).order(:index).first
    end

    def pending_approvals
      ToolInvocation.joins(:turn).where(silas_turns: { session_id: id }, approval_state: "required")
    end

    # Enqueue the next turn. One active turn per session — the partial unique
    # index is the backstop; this is the friendly front door. enqueue: false
    # creates the turn without scheduling it (callers that drive it themselves,
    # e.g. an awaited handoff running the loop inline).
    def continue(input:, enqueue: true)
      if active_turn
        raise TurnInProgressError, "session #{id} already has an active turn (##{active_turn.index})"
      end

      next_index = (turns.maximum(:index) || -1) + 1
      turn = turns.create!(index: next_index, input: input)
      AgentLoopJob.perform_later(turn.id) if enqueue
      turn
    rescue ActiveRecord::RecordNotUnique
      raise TurnInProgressError, "session #{id} already has an active turn"
    end
  end
end
