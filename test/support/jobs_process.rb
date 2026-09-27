# A stand-alone job process for test/jobs_process_test.rb: what bin/jobs
# will be (docs/history/plan-jobs.md Phase 6, Seam D), with intervals
# short enough for a test. Ready once its monk_processes row exists.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "monk/jobs"
require "monk/jobs/runtime"
require "monk/persistence/pg"
require_relative "jobs_process_jobs"

Monk::Persistence::Pg.register(
  JobsProcessJobs::DB,
  host: ENV.fetch("MONK_TEST_PG_HOST"),
  port: ENV.fetch("MONK_TEST_PG_PORT").to_i,
  user: ENV.fetch("MONK_TEST_PG_USER"),
  password: ENV.fetch("MONK_TEST_PG_PASSWORD"),
  dbname: ENV.fetch("MONK_TEST_PG_DATABASE"),
)
Monk::Jobs.configure(db_name: JobsProcessJobs::DB)

Monk::Jobs::Runtime.new(
  workers: 2, poll_interval: 0.05, tick_interval: 0.05, heartbeat_interval: 0.2,
  process_timeout: 1.0, shutdown_timeout: 5.0,
).run
