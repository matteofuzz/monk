require_relative "test_helper"
require "rbconfig"
require "monk/presence"

# Real web processes, each with its presence reactor, sharing nothing with
# this test but Postgres (ADR 0019): one reacts at a time, and when it is
# killed with -9, another takes over. Hosts or pods behave the same: the
# election is a Postgres lock.
class PresenceReactorProcessTest < Minitest::Test
  include PersistenceTestHelpers
  include PresenceTestHelpers

  DB_NAME = :presence_reactor_process_test_db
  SCRIPT = File.expand_path("support/presence_reactor_process.rb", __dir__)

  def setup
    Monk::Persistence::Pg.reset!
    @children = []
    skip_unless_postgres_available
    setup_presence_tables(DB_NAME)
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_table_if_exists(conn, "presence_reactor_results") }
    sql("CREATE TABLE presence_reactor_results (id serial PRIMARY KEY, value text NOT NULL)")
  end

  def teardown
    @children.dup.each { |pid| kill(pid) }
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_table_if_exists(conn, "presence_reactor_results")
        drop_presence_tables(conn)
      end
    end
    Monk::Persistence::Pg.reset!
  end

  def test_one_process_reacts_and_another_takes_over_when_it_is_killed
    first = start_process
    second = start_process

    reacting = Integer(signal_until_handled("u:1").split.first)
    assert_includes [first, second], reacting

    sql("DELETE FROM presence_reactor_results")
    notify(["u:2"])
    sleep 0.5
    assert_equal ["#{reacting} u:2"], results, "only one process reacts"

    kill(reacting)
    other = ([first, second] - [reacting]).first
    assert_equal "#{other} u:3", signal_until_handled("u:3")
  end

  private

  def start_process
    opts = pg_test_opts
    env = {
      "MONK_TEST_PG_HOST" => opts[:host], "MONK_TEST_PG_PORT" => opts[:port].to_s,
      "MONK_TEST_PG_USER" => opts[:user], "MONK_TEST_PG_PASSWORD" => opts[:password],
      "MONK_TEST_PG_DATABASE" => opts[:dbname],
    }
    pid = Process.spawn(env, RbConfig.ruby, "-W0", SCRIPT)
    @children << pid
    pid
  end

  def kill(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
    @children.delete(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def notify(subjects)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT pg_notify('monk_presence', $1)", [JSON.generate(subjects)])
    end
  end

  # A signal sent before a reactor listens is missed (as in production):
  # send until a process records it. Returns that record.
  def signal_until_handled(subject, timeout: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      notify([subject])
      sleep 0.2
      found = results.find { |value| value.end_with?(" #{subject}") }
      return found if found
    end
    flunk "no process reacted to #{subject} within #{timeout}s"
  end

  def results = sql("SELECT value FROM presence_reactor_results ORDER BY id").map { |row| row["value"] }

  def sql(query) = Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec(query) }
end
