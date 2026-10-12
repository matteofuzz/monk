# Background jobs on Postgres (Monk::Jobs), run by bin/jobs.
Monk::Generator.define(:jobs) do
  summary "Background jobs on Postgres"
  installed_if "config/jobs.rb"
  depends_on :postgres

  copy "config/jobs.rb", role: :wiring
  copy "bin/jobs", role: :wiring, executable: true
  copy "app/jobs/hello_job.rb", "app/routes/jobs.rb", role: :example
  copy "test/jobs_test.rb", role: :test
  migration "create_jobs_tables"

  queues = { "JOBS_WORKERS" => "2", "JOBS_QUEUES" => "mailers,default" }
  env :development, queues
  env :example, queues

  setup_section "jobs/setup.md"
  agents_section "jobs/agents.md"
  next_step "bin/jobs", note: "beside bin/server"
  example "jobs-enqueue", todo: "uncomment, or enqueue your own jobs from any route"
end
