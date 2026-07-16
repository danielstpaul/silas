# Chaos-only tuning: fast heartbeat/prune so supervisor-kill runs recover in
# seconds. Production uses saner values; recovery ≈ alive_threshold + rescuer cadence.
Rails.application.config.after_initialize do
  SolidQueue.process_heartbeat_interval = 1.second
  SolidQueue.process_alive_threshold = 2.seconds
end
