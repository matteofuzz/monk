$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
ENV["MONK_ENV"] ||= "production"

require "minitest/autorun"
require "stringio"
require "monk"

module EnvHelper
  def env_for(method, path)
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(""),
    }
  end
end

Minitest::Test.include(EnvHelper)

# Shared by tests that need a real Postgres connection (persistence_*_test.rb).
# Not included globally -- `include PersistenceTestHelpers` where needed.
module PersistenceTestHelpers
  def pg_test_opts
    {
      host: ENV.fetch("MONK_TEST_PG_HOST", "127.0.0.1"),
      port: ENV.fetch("MONK_TEST_PG_PORT", "5432").to_i,
      user: ENV.fetch("MONK_TEST_PG_USER", "postgres"),
      password: ENV.fetch("MONK_TEST_PG_PASSWORD", "postgres"),
      dbname: ENV.fetch("MONK_TEST_PG_DATABASE", "monk_test"),
    }
  end

  def postgres_available?
    return @postgres_available if defined?(@postgres_available)

    PG.connect(**pg_test_opts).finish
    @postgres_available = true
  rescue PG::Error
    @postgres_available = false
  end

  def skip_unless_postgres_available
    skip "no local Postgres reachable at #{pg_test_opts[:host]}:#{pg_test_opts[:port]} " \
      "(set MONK_TEST_PG_* env vars, or start one -- see docs/persistence-ractor-connections.md)" unless postgres_available?
  end
end
