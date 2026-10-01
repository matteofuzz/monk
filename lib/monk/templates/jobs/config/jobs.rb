require "monk"
require "monk/jobs"
require_relative "persistence"

# Background jobs (Monk::Jobs): enqueue from any route, e.g.
# HelloJob.enqueue("world"); bin/jobs runs them. Every job is a class under
# app/jobs/, which config/load.rb loads after this file, so the web process
# can enqueue it and bin/jobs can run it.
#
# The queue lives in the app's own database, so a job can be enqueued
# inside the app's own transaction: HelloJob.enqueue("world", conn: conn).
# Once the app has long-running transactions or heavy load, give the queue
# a database of its own -- register it in config/persistence.rb and pass
# its name here (Monk's docs/guides/jobs.md, "Keeping the queue healthy").
Monk::Jobs.configure(db_name: :primary)
