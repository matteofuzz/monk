require "timeout"

module Monk
  module Jobs
    # One worker Ractor's loop (docs/history/plan-jobs.md Phase 6): claim
    # from the queues in order, run the job, finish or fail it, and wait
    # poll_interval when there's nothing to claim. Plain module methods,
    # not blocks, so they're callable from any Ractor.
    module Worker
      # Failures that retrying can't fix.
      NEVER_RETRY = [UnknownJobError, NotImplementedError].freeze

      # The body of a worker Ractor, until the supervisor sends :stop on the
      # control port handed back through `hello`. A stop is only noticed
      # between jobs, never in the middle of one. `holding` tells the
      # supervisor which job this worker has, [index, id] after a claim and
      # [index, nil] once it's finished or failed, so a job whose worker
      # dies in between can be released.
      def self.run(adapter, process_id, queues, poll_interval, hello, holding, index)
        # The supervisor logs why a worker ended, backtrace included; don't
        # also dump it to stderr.
        Thread.current.report_on_exception = false
        control = Ractor::Port.new
        hello << control
        wake = Thread::Queue.new
        stopping = false
        Thread.new do
          control.receive
          stopping = true
          wake << :stop
        end

        until stopping
          claim = next_claim(adapter, queues, process_id)
          next wake.pop(timeout: poll_interval) unless claim

          holding << [index, claim.id]
          perform(adapter, process_id, claim)
          holding << [index, nil]
        end
      end

      def self.next_claim(adapter, queues, process_id)
        queues.each do |queue|
          claim = adapter.claim(queue, process_id)
          return claim if claim
        end
        nil
      end

      # Every exception fails the job, not only StandardErrors: one that
      # escaped would leave the job running inside a live process, which
      # pruning never touches. A non-StandardError is re-raised afterwards,
      # ending this Ractor so the supervisor starts a fresh one.
      def self.perform(adapter, process_id, claim)
        error = begin
          job = Monk::Jobs.lookup(claim.job_class)
          run_job(job, claim.args)
          nil
        rescue Exception => e # rubocop:disable Lint/RescueException
          e
        end
        return adapter.finish(claim.id, process_id) unless error

        record_failure(adapter, process_id, claim, error)
        raise error unless error.is_a?(StandardError) || error.is_a?(NotImplementedError)
      end

      def self.run_job(job, args)
        return job.perform(*args) unless job.timeout

        Timeout.timeout(job.timeout) { job.perform(*args) }
      end

      def self.record_failure(adapter, process_id, claim, error)
        # Phase 0.3: the interrupted query is still running on the server,
        # and this connection's next query would wait for it.
        adapter.reset_connection if error.is_a?(Timeout::Error)

        retry_in = NEVER_RETRY.any? { |klass| error.is_a?(klass) } ? nil : Monk::Jobs.backoff(claim.attempts)
        outcome = adapter.fail(claim.id, process_id, error: Monk::Jobs.describe_error(error), retry_in: retry_in)
        outcomes = { scheduled: "retrying in #{retry_in}s", failed: "failed for good" }
        what_next = outcomes.fetch(outcome, "no longer held")
        Monk::Log.error(
          "Monk::Jobs: #{claim.job_class} (job #{claim.id}, attempt #{claim.attempts}) failed with " \
          "#{error.class}: #{error.message} -- #{what_next}",
        )
      end
    end
  end
end
