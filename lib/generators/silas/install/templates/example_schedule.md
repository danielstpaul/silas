<%# Task-mode schedule: this markdown body becomes the turn input on each tick. %>
---
cron: "0 9 * * *"
# queue: default
---
Summarize yesterday's activity and post the digest.

# INERT until you run `bin/rails silas:schedules` (which compiles schedules into
# config/recurring.yml — cron that fires real work stays a reviewable git diff).
# For programmatic control, write app/agent/schedules/<name>.rb subclassing
# Silas::Schedule::Handler with `cron`/`every` and a `#call` method instead.
