## jobs

Background jobs on the app's own Postgres. Two migrations create the
queue's tables and the recurring jobs' one: run `bin/setup_db` and `DB_NAME={{app}}_test bin/setup_db`
(postgres, above).

### Run them

`bin/jobs` is the process that runs jobs, next to `bin/server`:

```bash
bin/jobs
```

`JOBS_WORKERS` (in `.env`) is how many jobs run at once, and `JOBS_QUEUES`
which queues it takes them from, in order: `mailers,default` serves mail
first. `TERM` or Ctrl-C lets the jobs in hand finish before it exits. In
production it's one more process from the same image, with `bin/jobs` as
its command.

### Recurring jobs

Declare schedules in `config/recurring.rb`:

```ruby
Monk::Jobs.recurring "purge_sessions", PurgeSessions, cron: "0 3 * * *"
```

Cron times are UTC. A running `bin/jobs` enqueues each occurrence once,
however many are running; with none running, nothing fires, and on
restart only the latest missed occurrence runs. A new task first runs at
its next occurrence, not on deploy.

### Check it works

1. `bundle exec rake test` runs `test/jobs_test.rb`, which enqueues the
   demo job (`app/jobs/hello_job.rb`) and runs it.
2. By hand, with `bin/jobs` running: in `bin/console`,
   `HelloJob.enqueue("Ann")`, and `log/development.log` shows
   `Hello, Ann, from a background job`.
3. The example: uncomment the `jobs-enqueue` block in `app/routes/jobs.rb`,
   restart `bin/server`, and
   `curl -X POST "http://localhost:9292/jobs/hello?name=Bob"`.
4. A recurring job, in a test: `Monk::Jobs.run_scheduler!(at: time)` runs
   the schedule as if the clock read `time`. The first call only records
   where the task is; a second call at the next occurrence enqueues it,
   and `Monk::Jobs.drain!` runs it. The `jobs-recurring` example in
   `config/recurring.rb` schedules the demo job every hour.
