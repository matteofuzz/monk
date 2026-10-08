# Monk::Jobs' demo route: enqueues the demo job (app/jobs/hello_job.rb)
# for bin/jobs to run.
#   curl -X POST "http://localhost:9292/jobs/hello?name=Ann"
class App
  post("/jobs/hello") { json(enqueued: HelloJob.enqueue(params[:name] || "world")) }
end
