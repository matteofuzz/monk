# Recurring jobs: bin/jobs enqueues each one on its schedule, once per
# occurrence however many job processes are running. Loaded after app/,
# since each names a job class.
#
#   Monk::Jobs.recurring "<key>", JobClass, cron: "<expression>", args: [...]
#
# The key is the task's identity in the database: keep it when renaming
# the class. cron: is a five-field cron expression (minute hour
# day-of-month month day-of-week, or @hourly, @daily, ...), always in UTC.
# A new task first runs at its next occurrence, not on deploy; after
# downtime only the latest missed occurrence runs.
# skip_if_pending: true skips an occurrence while the previous run hasn't
# finished. Monk's docs/guides/jobs.md, "Recurring jobs".

# With auth (monk add auth): deletes expired sessions and login tokens, and
# old login requests, every night at 03:17 UTC.
Monk::Jobs.recurring "monk_auth_sweep", Monk::Auth::Sweep, cron: "17 3 * * *" if defined?(Monk::Auth::Sweep)

# monk:example jobs-recurring -- the demo job (app/jobs/hello_job.rb) at the top of every hour.
# Monk::Jobs.recurring "hello_hourly", HelloJob, cron: "@hourly", args: ["cron"]
# monk:end
