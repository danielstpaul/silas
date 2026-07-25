module Silas
  # One compaction row replaces session turns 0..up_to_turn_index with a
  # persisted summary. Written exactly once (the unique index on
  # session_id + up_to_turn_index is the compare-and-swap claim), read
  # deterministically forever after — which is what lets MessageBuilder stay
  # byte-identical across crash replays: the summary is a row, never a
  # runtime computation.
  class Compaction < ApplicationRecord
    STATUSES = %w[pending completed].freeze

    belongs_to :session, class_name: "Silas::Session"
    belongs_to :up_to_turn, class_name: "Silas::Turn"

    validates :status, inclusion: { in: STATUSES }
    validates :up_to_turn_index, presence: true

    scope :completed, -> { where(status: "completed") }

    def completed? = status == "completed"

    # The compaction MessageBuilder applies when building turn: the newest
    # completed summary strictly before it. (A compaction can never cover its
    # own turn — it is created during turn N covering 0..N-1 — so `<` is
    # always satisfiable; it also keeps an eval or replay of an older turn
    # from seeing a summary written after it.)
    def self.latest_for(turn)
      completed.where(session_id: turn.session_id)
               .where(up_to_turn_index: ...turn.index)
               .order(:up_to_turn_index).last
    end
  end
end
