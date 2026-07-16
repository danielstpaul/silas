module Silas
  # The recurring entry Solid Queue fires enqueues this thin job, which resolves
  # the schedule by name and triggers it. A tick is fire-and-forget: it never
  # retry-loops (a failed tick shouldn't pile up), and the turn it starts is
  # itself fully durable from :prepare onward.
  class ScheduleJob < ActiveJob::Base
    queue_as { Silas.config.queue_name }

    discard_on(StandardError) do |job, error|
      Rails.logger&.error("silas: schedule #{job.arguments.first} failed: #{error.class}: #{error.message}")
    end

    def perform(schedule_name)
      schedule = Silas.schedules.find { |s| s.name == schedule_name }
      unless schedule
        Rails.logger&.warn("silas: no schedule #{schedule_name.inspect} (stale recurring entry? run `bin/rails silas:schedules`)")
        return
      end
      schedule.trigger!
    end
  end
end
