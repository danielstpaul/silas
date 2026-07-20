module Silas
  # One remembered fact. Triple-ish (subject · attribute · content) with
  # provenance (which turn wrote it) and supersession: a new fact about the
  # same (agent, scope, subject, attribute) retires the old one — temporal
  # versioning without a temporal store. Edges between memories are a
  # deliberate not-yet: add them when a real agent needs multi-hop.
  class Memory < ApplicationRecord
    self.table_name = "silas_memories"

    SCOPES = %w[agent app].freeze
    validates :scope, inclusion: { in: SCOPES }
    validates :agent_name, :subject, :content, presence: true

    scope :active, -> { where(status: "active") }

    # Write-through with supersession. attribute nil = free-form note about the
    # subject (accumulates); attribute present = the triple's slot (supersedes).
    def self.remember!(agent_name:, subject:, content:, attribute: nil, scope: "agent", turn: nil)
      transaction do
        record = create!(agent_name:, scope:, subject: subject.to_s.strip.downcase,
                         attribute_name: attribute.presence&.strip&.downcase, content:,
                         session_id: turn&.session_id, turn_id: turn&.id)
        if record.attribute_name
          active.where(agent_name:, scope:, subject: record.subject, attribute_name: record.attribute_name)
                .where.not(id: record.id)
                .update_all(status: "superseded", superseded_by_id: record.id, updated_at: Time.current)
        end
        record
      end
    end

    # What an agent can see: its own memories + app-shared ones. Subject-matched
    # first (when subjects given), then most recent.
    def self.recall(agent_name:, subjects: [], limit: 10)
      visible = active.where("agent_name = :a OR scope = 'app'", a: agent_name)
      if subjects.any?
        keys = subjects.map { |s| s.to_s.strip.downcase }
        matched = visible.where(subject: keys).order(created_at: :desc).limit(limit).to_a
        rest = visible.where.not(subject: keys).order(created_at: :desc).limit(limit - matched.size)
        matched + rest
      else
        visible.order(created_at: :desc).limit(limit).to_a
      end
    end

    def to_line
      head = attribute_name ? "#{subject} · #{attribute_name}: " : "#{subject}: "
      head + content
    end
  end
end
