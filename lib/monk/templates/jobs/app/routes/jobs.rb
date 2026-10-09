# Routes that hand work to bin/jobs (monk add jobs).
#
# monk:example jobs-enqueue -- a route enqueueing the demo job (app/jobs/hello_job.rb).
# # bin/jobs runs it, and its line lands in log/development.log:
# #   curl -X POST "http://localhost:9292/jobs/hello?name=Ann"
# class App
#   post("/jobs/hello") { json(enqueued: HelloJob.enqueue(params[:name] || "world")) }
# end
# monk:end
