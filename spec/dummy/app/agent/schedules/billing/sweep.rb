class Agent::Schedules::Billing::Sweep < Silas::Schedule::Handler
  cron "0 2 * * *"
  queue :low

  # Test observability: records that it ran (see registry/schedule specs).
  def self.runs = @runs ||= []

  def call
    self.class.runs << schedule.name
  end
end
