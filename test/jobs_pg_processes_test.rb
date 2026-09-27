require_relative "test_helper"
require "monk/jobs"
require "monk/persistence/pg"

# Job processes on the Postgres adapter: registration, heartbeat, pruning
# a dead process's jobs back to available, and a graceful deregister
# (docs/history/plan-jobs.md Phase 6, Seam B).
module JobsPgProcessesJobs
  class Receipt < Monk::Job
  end
end

class JobsPgProcessesTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :jobs_pg_processes_test_db

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    skip_unless_postgres_available

    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
  end

  def teardown
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_jobs_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
  end

  def test_register_process_returns_a_new_id_with_its_host_and_pid
    id = adapter.register_process(hostname: "box-1", pid: 4242)

    row = process_row(id)
    assert_equal ["box-1", 4242], [row["hostname"], row["pid"]]
    refute_equal id, adapter.register_process(hostname: "box-1", pid: 4243)
  end

  def test_heartbeat_moves_last_heartbeat_forward
    id = adapter.register_process(hostname: "box-1", pid: 1)
    age_process(id, 60)

    adapter.heartbeat(id, hostname: "box-1", pid: 1)

    assert_operator seconds_since_heartbeat(id), :<, 5
  end

  # A process that stalled long enough to be pruned comes back under the
  # same id; the jobs it lost stay with whoever reclaimed them.
  def test_heartbeat_restores_a_process_row_that_was_pruned
    id = adapter.register_process(hostname: "box-1", pid: 1)
    age_process(id, 600)
    adapter.prune(60)
    assert_nil process_row(id)

    adapter.heartbeat(id, hostname: "box-1", pid: 1)

    assert_equal "box-1", process_row(id)["hostname"]
  end

  def test_prune_releases_a_dead_processs_running_jobs_and_deletes_it
    dead = adapter.register_process(hostname: "gone", pid: 1)
    job = running_job(dead)
    age_process(dead, 600)

    assert_equal 1, adapter.prune(60)

    assert_nil process_row(dead)
    row = job_row(DB_NAME, job)
    assert_equal ["available", nil, nil], [row["state"], row["locked_by"], row["locked_at"]]
    assert_equal 1, row["attempts"], "the attempt stays counted"
  end

  def test_prune_leaves_live_processes_and_their_jobs_alone
    live = adapter.register_process(hostname: "here", pid: 1)
    job = running_job(live)

    assert_equal 0, adapter.prune(60)

    refute_nil process_row(live)
    assert_equal "running", job_row(DB_NAME, job)["state"]
  end

  # E.g. a drain! that crashed mid-job: running, with no process row at
  # all. Released only after the same grace period.
  def test_prune_releases_long_running_jobs_that_have_no_process_row
    orphan = running_job(Monk::Jobs::DRAIN_PROCESS_ID)
    recent = running_job(Monk::Jobs::DRAIN_PROCESS_ID)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("UPDATE monk_jobs SET locked_at = now() - interval '600 seconds' WHERE id = $1", [orphan])
    end

    assert_equal 1, adapter.prune(60)

    assert_equal "available", job_row(DB_NAME, orphan)["state"]
    assert_equal "running", job_row(DB_NAME, recent)["state"]
  end

  def test_deregister_releases_the_processs_running_jobs_and_deletes_it
    mine = adapter.register_process(hostname: "me", pid: 1)
    other = adapter.register_process(hostname: "other", pid: 2)
    my_job = running_job(mine)
    their_job = running_job(other)

    adapter.deregister(mine)

    assert_nil process_row(mine)
    assert_equal "available", job_row(DB_NAME, my_job)["state"]
    assert_equal "running", job_row(DB_NAME, their_job)["state"]
  end

  private

  def adapter
    Monk::Jobs.adapter
  end

  def running_job(process_id)
    id = JobsPgProcessesJobs::Receipt.enqueue
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "UPDATE monk_jobs SET state = 'running', locked_by = $2, locked_at = now(), attempts = 1 WHERE id = $1",
        [id, process_id],
      )
    end
    id
  end

  def process_row(id)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM monk_processes WHERE id = $1", [id]).first
    end
  end

  def age_process(id, seconds)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "UPDATE monk_processes SET last_heartbeat_at = now() - $2::float8 * interval '1 second' WHERE id = $1",
        [id, seconds],
      )
    end
  end

  def seconds_since_heartbeat(id)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params(
        "SELECT extract(epoch FROM now() - last_heartbeat_at)::float8 FROM monk_processes WHERE id = $1", [id],
      ).getvalue(0, 0)
    end
  end
end
