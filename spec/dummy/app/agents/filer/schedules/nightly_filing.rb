# A named agent's handler-form schedule: full programmatic control, resolved
# as Agents::Filer::Schedules::NightlyFiling.
class Agents::Filer::Schedules::NightlyFiling < Silas::Schedule::Handler
  cron "0 2 * * *"

  def call
    Silas.agent("filer").start(input: "File everything left in the tray.",
                               metadata: { "trigger" => "schedule", "schedule" => schedule.name })
  end
end
