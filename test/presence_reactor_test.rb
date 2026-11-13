require_relative "test_helper"
require "monk/presence"

# bin/server's side of presence (ADR 0019): one Ractor among the web
# processes, elected by an advisory lock, LISTENs for the WebSocket
# processes' signals and calls on_change with the subjects' current status.
class PresenceReactorTest < Minitest::Test
  include PersistenceTestHelpers
  include PresenceTestHelpers

  DB_NAME = :presence_reactor_test_db

  # on_change runs in the reactor's Ractor, so the blocks are built here,
  # where self (the class) is shareable, and report through a port.
  RECEIVED = Ractor::Port.new
  RECORD = proc { |changes| RECEIVED << changes }
  FAIL_ON_BOOM = proc do |changes|
    raise "boom" if changes.key?("u:boom")

    RECEIVED << changes
  end

  def setup
    Monk::Persistence::Pg.reset!
    skip_unless_postgres_available
    setup_presence_tables(DB_NAME)
    @store = Monk::Presence::Store.new(db_name: DB_NAME, grace: 20, process_timeout: 30)
    @process = @store.register_process(hostname: "box-1", pid: 1)
    # As Monk.boot does before bin/server starts the reactor: the database
    # settings become readable from its Ractor.
    Monk.freeze!
    @reactors = []
    drain
  end

  def teardown
    @reactors&.each { |r| Monk::Presence::Reactor.stop(r) }
    Monk::Presence.reset!
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_presence_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
  end

  def test_a_signal_calls_on_change_with_the_subjects_current_status
    Monk::Presence.configure(db_name: DB_NAME)
    start_reactor(RECORD)
    @store.flush(@process, online: ["u:1"], away: ["u:2"])
    @store.settle(%w[u:1 u:2], notify: true)

    changes = signal_until_received(%w[u:1 u:2])

    assert_equal({ "u:1" => { status: :online, last_seen_at: nil }, "u:2" => { status: :away, last_seen_at: nil } },
      changes,)
  end

  def test_only_the_lock_holder_reacts_and_another_takes_over_when_it_stops
    Monk::Presence.configure(db_name: DB_NAME)
    first = start_reactor(RECORD)
    signal_until_received(["u:1"])
    start_reactor(RECORD)

    notify(["u:1"])
    receive
    assert_nil receive(timeout: 0.6), "a second reactor reacted too"

    Monk::Presence::Reactor.stop(first)
    @reactors.delete(first)
    refute_nil signal_until_received(["u:1"]), "the other reactor didn't take over"
  end

  def test_an_error_in_on_change_is_logged_and_the_next_signal_still_handled
    Monk::Presence.configure(db_name: DB_NAME)
    output = with_log do |dir|
      # As after Monk.boot, so the reactor's Ractor can write the log.
      Monk::Log.freeze_registry!
      start_reactor(FAIL_ON_BOOM)
      signal_until_received(["u:1"])

      notify(["u:boom"])
      notify(["u:2"])

      assert_equal ["u:2"], receive.keys
      File.read(File.join(dir, "test.log"))
    end

    assert_match(/Monk::Presence on_change failed.*boom/, output)
  end

  # Postgres restarted, or a proxy dropped the connection.
  def test_a_reactor_whose_connection_drops_reconnects_and_reacts_again
    Monk::Presence.configure(db_name: DB_NAME)
    start_reactor(RECORD)
    signal_until_received(["u:1"])

    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec("SELECT pg_terminate_backend(pid) FROM pg_stat_activity " \
                "WHERE pid <> pg_backend_pid() AND query LIKE 'LISTEN monk_presence%'")
    end

    refute_nil signal_until_received(["u:2"]), "the reactor didn't come back"
  end

  # A reactor host that vanishes without closing its connection: Postgres
  # drops the session, and the lock, in about 25 s, not after TCP's
  # default 2 hours.
  def test_the_reactor_connection_has_short_tcp_keepalives
    conn = Monk::Presence::Reactor.connect(Monk::Persistence::Pg.connection_options(DB_NAME))

    settings = %w[tcp_keepalives_idle tcp_keepalives_interval tcp_keepalives_count].map do |name|
      conn.exec("SHOW #{name}").getvalue(0, 0)
    end
    assert_equal %w[10 5 3], settings
  ensure
    conn&.close
  end

  def test_start_reactor_needs_an_on_change
    Monk::Presence.configure(db_name: DB_NAME)

    assert_nil Monk::Presence.start_reactor!
  end

  def test_on_change_rejects_a_block_that_is_not_shareable
    error = assert_raises(Monk::UnshareableBlockError) { Monk::Presence.on_change { |changes| changes } }

    assert_match(/on_change block is not Ractor-shareable/, error.message)
  end

  private

  def start_reactor(hook)
    reactor = Monk::Presence::Reactor.start(Monk::Persistence::Pg.connection_options(DB_NAME), hook,
      retry_interval: 0.2,)
    @reactors << reactor
    reactor
  end

  def notify(subjects)
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT pg_notify('monk_presence', $1)", [JSON.generate(subjects)])
    end
  end

  # A reactor LISTENs only once it holds the lock, so a signal sent
  # before that is missed (as in production): send until one lands.
  def signal_until_received(subjects, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      notify(subjects)
      changes = receive(timeout: 0.2)
      if changes
        drain
        return changes
      end
    end
    nil
  end

  # One receiving thread at a time, across tests: one left waiting after a
  # timeout is reused, or it would take the next test's message.
  class << self
    attr_accessor :waiting
  end

  def receive(timeout: 5)
    waiting = (self.class.waiting ||= Thread.new { RECEIVED.receive })
    return nil unless waiting.join(timeout)

    self.class.waiting = nil
    waiting.value
  end

  def drain
    nil while receive(timeout: 0.05)
  end
end
