require_relative "test_helper"
require "rbconfig"
require "monk/jobs"
require "monk/persistence/pg"
require_relative "support/jobs_process_jobs"

# Real job processes (docs/history/plan-jobs.md Phase 6, Seam D): a child
# process per bin/jobs, sharing nothing with this test but Postgres, and
# stopped the two ways production stops one -- TERM, and kill -9.
class JobsProcessTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = JobsProcessJobs::DB
  SCRIPT = File.expand_path("support/jobs_process.rb", __dir__)

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    @children = []
    skip_unless_postgres_available

    setup_jobs_tables(DB_NAME)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      drop_table_if_exists(conn, "jobs_process_results")
      conn.exec("CREATE TABLE jobs_process_results (value TEXT NOT NULL)")
    end
    Monk::Jobs.configure(db_name: DB_NAME)
  end

  def teardown
    @children.each { |pid| kill(pid, "KILL") }
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_jobs_tables(conn)
        drop_table_if_exists(conn, "jobs_process_results")
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
  end

  def test_a_job_process_runs_jobs_and_stops_cleanly_on_term
    3.times { |i| JobsProcessJobs::Record.enqueue("job #{i}") }
    pid = start_job_process

    wait_until { results.size == 3 }
    status = stop(pid, "TERM")

    assert_predicate status, :success?
    assert_equal 0, count_rows(DB_NAME, "monk_processes")
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  def test_term_lets_the_job_in_flight_finish
    JobsProcessJobs::Long.enqueue(1.0, "in flight")
    pid = start_job_process
    wait_until { results.include?("in flight started") }

    stop(pid, "TERM")

    assert_includes results, "in flight finished"
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  # The at-least-once case (Decision 4): the job was running in the
  # killed process, so it starts again elsewhere -- and finishes once.
  def test_a_killed_processs_job_is_rerun_exactly_once_by_another_process
    JobsProcessJobs::Long.enqueue(1.0, "orphan")
    killed = start_job_process
    wait_until { results.include?("orphan started") }

    stop(killed, "KILL")
    survivor = start_job_process

    wait_until(timeout: 10) { results.include?("orphan finished") }
    sleep 1.5 # time for a wrong second run to show up
    assert_equal 2, results.count("orphan started")
    assert_equal 1, results.count("orphan finished")
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
    stop(survivor, "TERM")
  end

  # Every connection the job process has, the supervisor's included, as
  # when Postgres restarts under it: it reconnects and carries on.
  def test_a_job_process_survives_losing_every_database_connection
    pid = start_job_process
    JobsProcessJobs::Record.enqueue("before")
    wait_until { results.include?("before") }

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec(<<~SQL)
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
        WHERE datname = current_database() AND pid <> pg_backend_pid()
      SQL
    end
    JobsProcessJobs::Record.enqueue("after")

    wait_until(timeout: 10) { results.include?("after") }
    assert_predicate stop(pid, "TERM"), :success?
    assert_equal 0, count_rows(DB_NAME, "monk_processes")
  end

  private

  def start_job_process
    opts = pg_test_opts
    env = {
      "MONK_TEST_PG_HOST" => opts[:host],
      "MONK_TEST_PG_PORT" => opts[:port].to_s,
      "MONK_TEST_PG_USER" => opts[:user],
      "MONK_TEST_PG_PASSWORD" => opts[:password],
      "MONK_TEST_PG_DATABASE" => opts[:dbname],
    }
    pid = Process.spawn(env, RbConfig.ruby, "-W0", SCRIPT)
    @children << pid
    wait_until(timeout: 30) { registered?(pid) }
    pid
  end

  def stop(pid, signal)
    Process.kill(signal, pid)
    _, status = Process.wait2(pid)
    @children.delete(pid)
    status
  end

  def kill(pid, signal)
    Process.kill(signal, pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def registered?(pid)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT 1 FROM monk_processes WHERE pid = $1", [pid]).ntuples.positive?
    end
  end

  def results
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec("SELECT value FROM jobs_process_results").map { |row| row["value"] }
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk("condition not met within #{timeout}s") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
