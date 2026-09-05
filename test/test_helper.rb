$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
ENV["MONK_ENV"] ||= "production"

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
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

# Shared by views_test.rb and assets_test.rb: a throwaway views/ or
# public/ root on disk, torn down after the block, with the global
# Monk::Views / Monk::Assets state reset either way.
module ViewTestHelpers
  def with_views(templates)
    with_tree("monk-views", templates) do |dir|
      Monk::Views.reset!
      Monk::Views.root = dir
      begin
        yield dir
      ensure
        Monk::Views.reset!
      end
    end
  end

  def with_assets(files)
    with_tree("monk-assets", files) do |dir|
      Monk::Assets.reset!
      Monk::Assets.root = dir
      begin
        yield dir
      ensure
        Monk::Assets.reset!
      end
    end
  end

  # Monk reads MONK_ENV once, at boot, never per request -- so a test
  # that wants development behavior has to set it before .freeze!.
  def with_monk_env(value)
    with_env("MONK_ENV", value) { yield }
  end

  # Sets (or, given nil, clears) an arbitrary ENV var for the duration of
  # the block, restoring whatever was there before either way.
  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  # Monk::Settings is global, module-level state, same as Monk::Assets/
  # Monk::Views -- reset on both sides of the block so one test's
  # declared keys never leak into another's.
  def with_settings
    Monk::Settings.reset!
    yield
  ensure
    Monk::Settings.reset!
  end

  def write_file(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  private

  def with_tree(prefix, files)
    Dir.mktmpdir(prefix) do |dir|
      files.each { |relative, content| write_file(dir, relative, content) }
      yield dir
    end
  end
end

Minitest::Test.include(ViewTestHelpers)

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

# Shared by tests that need real login_tokens/sessions tables and a
# configured Monk::Auth (auth_test.rb, auth_helpers_test.rb). Include
# PersistenceTestHelpers alongside this -- it's built on top of it.
module AuthTestHelpers
  def setup_auth_tables(db_name)
    skip_unless_postgres_available
    Monk::Persistence::Pg.register(db_name, **pg_test_opts)
    Monk::Persistence::Pg.checkout(db_name) do |conn|
      drop_auth_tables(conn)
      conn.exec(<<~SQL)
        CREATE TABLE login_tokens (
          id BIGSERIAL PRIMARY KEY,
          email TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          redirect_to TEXT,
          expires_at TIMESTAMPTZ NOT NULL,
          used_at TIMESTAMPTZ,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
      SQL
      conn.exec(<<~SQL)
        CREATE TABLE sessions (
          id BIGSERIAL PRIMARY KEY,
          subject TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          expires_at TIMESTAMPTZ NOT NULL,
          revoked_at TIMESTAMPTZ,
          created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
      SQL
    end
    Monk::Auth.configure(
      db_name: db_name, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
      redirect_allowlist: ["/dashboard"],
    )
  end

  def drop_auth_tables(conn)
    conn.exec("DROP TABLE IF EXISTS sessions")
    conn.exec("DROP TABLE IF EXISTS login_tokens")
  end
end
