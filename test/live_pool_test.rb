require_relative "test_helper"
require "json"
require "timeout"
require "socket"
require "securerandom"
require "monk/websocket"
require "monk/live"
require "monk/persistence/pg"

# Rules at module scope, so they're Ractor-shareable (self is a Module).
module LivePoolRules
  RUNS_IN_THE_POOL = proc { |_subject, _topic| Ractor.current[:monk_pool] == :live }
  ROOM_EXISTS = proc { |_subject, topic| LivePoolQueries.room_exists?(topic) }
end

module LivePoolQueries
  DB = :live_pool_test_db

  def self.room_exists?(topic)
    Monk::Persistence::Pg.checkout(DB) do |conn|
      conn.exec_params("SELECT 1 FROM live_pool_rooms WHERE topic = $1", [topic]).ntuples.positive?
    end
  end
end

# Monk::Live.authorize(..., db_pool:) (docs/history/plan-pg-pool.md, phase
# 7): a rule that queries the database runs in a pool, so checking a
# subscription doesn't open a connection in every socket's Ractor.
class LivePoolTest < Minitest::Test
  include WebSocketTestHelpers
  include PersistenceTestHelpers

  DB_NAME = LivePoolQueries::DB

  def setup
    Monk::Live.reset!
    Monk::Persistence::Pg.reset!
  end

  def teardown
    super # WebSocketTestHelpers: stops the server thread
    drop_rooms_table if postgres_available?
    Monk::Live.reset!
    Monk::Persistence::Pg.reset!
  end

  def test_a_rule_with_db_pool_runs_in_that_pool
    start_live_pool(size: 1)
    Monk::Live.authorize("pooled:*", anonymous: true, db_pool: :live, &LivePoolRules::RUNS_IN_THE_POOL)
    Monk::Live.authorize("here:*", anonymous: true, &LivePoolRules::RUNS_IN_THE_POOL)

    assert Monk::Live.authorized?(nil, "pooled:1")
    refute Monk::Live.authorized?(nil, "here:1"), "control: without db_pool the rule runs in the caller's Ractor"
  end

  def test_a_pooled_rule_that_says_no_denies
    start_live_pool(size: 1)
    create_rooms_table("rooms:1")
    Monk::Live.authorize("rooms:*", anonymous: true, db_pool: :live, &LivePoolRules::ROOM_EXISTS)

    assert Monk::Live.authorized?(nil, "rooms:1")
    refute Monk::Live.authorized?(nil, "rooms:2")
  end

  # Fails closed like any rule, but says why: silently denying every
  # subscription because start_pools! is missing would be hard to find.
  def test_a_rule_whose_pool_is_not_started_denies_and_logs_why
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
    Monk::Persistence::Pg.pool(:live, db: DB_NAME, size: 1)
    Monk::Live.authorize("rooms:*", anonymous: true, db_pool: :live, &LivePoolRules::ROOM_EXISTS)

    allowed, log = with_log do |dir|
      with_settings do
        Monk::Settings.freeze_registry!
        Monk::Log.freeze_registry!
        [Monk::Live.authorized?(nil, "rooms:1"), File.read(File.join(dir, "test.log"))]
      end
    end

    refute allowed
    assert_match(/ERROR .*rooms:\*.*Monk::PoolNotStartedError/, log)
  end

  def test_db_pool_must_be_a_pool_name
    assert_raises(ArgumentError) do
      Monk::Live.authorize("rooms:*", db_pool: "live", &LivePoolRules::ROOM_EXISTS)
    end
  end

  # The real handler over real sockets, each in its own Ractor: the
  # database sees the pool's connections, not one per socket.
  def test_open_pages_checking_a_pooled_rule_share_the_pools_connections
    start_live_pool(size: 2)
    create_rooms_table("rooms:1")
    registry = Monk::WebSocket::Registry.new
    Monk::Live.configure(registry: registry)
    Monk::Live.authorize("rooms:*", anonymous: true, db_pool: :live, &LivePoolRules::ROOM_EXISTS)
    server = start_server(&Monk::Live::HANDLER)

    sockets = Array.new(10) { TCPSocket.new("127.0.0.1", server.port).tap { |socket| handshake!(socket) } }
    replies = sockets.map { |socket| subscribe(socket, %w[rooms:1 rooms:2]) }

    expected = [{ "topics" => ["rooms:1"], "denied" => ["rooms:2"] }] * 10
    assert_equal(expected, replies.map { |reply| reply.slice("topics", "denied") })
    assert_equal 2, connection_count
  ensure
    sockets&.each(&:close)
  end

  private

  def start_live_pool(size:)
    skip_unless_postgres_available
    @application_name = "monk_live_pool_test_#{SecureRandom.hex(4)}"
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts, application_name: @application_name)
    Monk::Persistence::Pg.pool(:live, db: DB_NAME, size: size)
    Monk::Persistence::Pg.start_pools!(:live)
  end

  def create_rooms_table(*topics)
    conn = PG.connect(**pg_test_opts)
    conn.exec("DROP TABLE IF EXISTS live_pool_rooms")
    conn.exec("CREATE TABLE live_pool_rooms (topic text PRIMARY KEY)")
    topics.each { |topic| conn.exec_params("INSERT INTO live_pool_rooms VALUES ($1)", [topic]) }
  ensure
    conn&.close
  end

  def drop_rooms_table
    conn = PG.connect(**pg_test_opts)
    drop_table_if_exists(conn, "live_pool_rooms")
  ensure
    conn&.close
  end

  def subscribe(socket, topics)
    socket.write(Monk::WebSocket::Frame.encode(JSON.generate(op: "subscribe", topics: topics), opcode: 0x1))
    JSON.parse(Timeout.timeout(3) { read_frame(socket) })
  end

  def connection_count
    conn = PG.connect(**pg_test_opts)
    result = conn.exec_params("SELECT count(*) FROM pg_stat_activity WHERE application_name = $1", [@application_name])
    result.getvalue(0, 0).to_i
  ensure
    conn&.close
  end
end
