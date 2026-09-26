require_relative "test_helper"
require "monk/persistence/pg"

# json/jsonb columns come back as Ruby values through Monk::Persistence::Pg's
# connections. pg 1.6.3's own JSON decoder calls
# JSON.parse(string, quirks_mode: true), a keyword json 3 removed, so
# without Monk's own decoder every json/jsonb read raised ArgumentError.
class PersistencePgJsonTest < Minitest::Test
  include PersistenceTestHelpers

  DB_NAME = :persistence_pg_json_test_db
  QUERY = <<~SQL.freeze
    SELECT '{"a": [1, "é", null]}'::jsonb AS object, '[true, 2.5]'::json AS array,
      '"text"'::jsonb AS string, '7'::json AS number, 'null'::jsonb AS json_null,
      NULL::jsonb AS sql_null, now() AS timestamp, 42 AS integer
  SQL

  def setup
    Monk::Persistence::Pg.reset!
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(DB_NAME, **pg_test_opts)
  end

  def teardown
    Monk::Persistence::Pg.reset!
  end

  def test_json_and_jsonb_columns_decode_to_ruby_values
    row = Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec(QUERY).first }

    assert_equal({ "a" => [1, "é", nil] }, row["object"])
    assert_equal [true, 2.5], row["array"]
    assert_equal "text", row["string"]
    assert_equal 7, row["number"]
    assert_nil row["json_null"]
    assert_nil row["sql_null"]
  end

  # Replacing the JSON decoders mustn't lose pg's other defaults.
  def test_other_types_still_decode
    row = Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec(QUERY).first }

    assert_instance_of Time, row["timestamp"]
    assert_equal 42, row["integer"]
  end

  # Each Ractor opens its own connection, so the decoder has to be
  # installable from a worker Ractor too.
  def test_json_decodes_on_a_worker_ractors_own_connection
    Monk.freeze!

    value = Ractor.new(DB_NAME, QUERY) do |db_name, query|
      Monk::Persistence::Pg.checkout(db_name) { |conn| conn.exec(query).first["object"] }
    end.value

    assert_equal({ "a" => [1, "é", nil] }, value)
  end
end
