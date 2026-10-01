require_relative "test_helper"
require "tmpdir"
require "open3"
require "monk/scaffold"
require "monk/live"

# `monk new APP --live`: the Monk::Live wiring, so a fresh app has a page
# whose open tabs update when another request changes server state.
class ScaffoldLiveTest < Minitest::Test
  include RedisTestHelpers

  EXE = File.expand_path("../exe/monk", __dir__)

  def test_live_writes_the_demo_wiring_from_the_live_templates
    in_app do |dest|
      assert_equal template("live/config/live.rb"), read(dest, "config/live.rb")
      assert_equal template("live/app/app.rb"), read(dest, "app/app.rb")
      assert_equal template("base/config.ru"), read(dest, "config.ru")
      assert_equal template("live/bin/websocket_server"), read(dest, "bin/websocket_server")
      assert_equal template("live/app/views/index.erb"), read(dest, "app/views/index.erb")
      assert_equal template("live/app/views/live/_hits.erb"), read(dest, "app/views/live/_hits.erb")
    end
  end

  def test_live_copies_the_client_files_out_of_the_gem_byte_for_byte
    in_app do |dest|
      client_files = Dir.children(Monk::Live.client_dir).sort

      assert_includes client_files, "monk_live.js"
      assert_equal client_files, Dir.children(File.join(dest, "public/js/monk_live")).sort
      client_files.each do |name|
        assert_equal File.read(File.join(Monk::Live.client_dir, name)), read(dest, "public/js/monk_live/#{name}")
      end
    end
  end

  def test_live_adds_the_meta_tag_and_module_script_to_the_layout_head
    in_app do |dest|
      layout = read(dest, "app/views/layouts/app.erb")

      assert_includes layout, %(<meta name="monk-live-url" content="<%= settings[:live_ws_url] %>">)
      assert_includes layout, %(<script type="module" src="<%= asset_path "/js/monk_live/monk_live.js" %>"></script>)
      assert_operator layout.index("monk-live-url"), :<, layout.index("</head>")
    end
  end

  # bin/server and bin/websocket_server are separate processes: Redis is how
  # a publish in one reaches a connection in the other.
  def test_live_implies_redis
    in_app do |dest|
      assert_includes read(dest, "Gemfile"), %(gem "redis")
      assert_includes read(dest, ".env"), "REDIS_URL=redis://localhost:6379/0"
    end
  end

  def test_live_makes_the_websocket_server_executable
    in_app do |dest|
      assert_equal 0o111, File.stat(File.join(dest, "bin/websocket_server")).mode & 0o111
    end
  end

  def test_live_setup_md_walks_through_running_it
    in_app do |dest|
      setup = read(dest, "SETUP.md")

      assert_includes setup, "Monk::Live"
      assert_includes setup, "bin/websocket_server"
      assert_includes setup, "REDIS_URL"
    end
  end

  def test_every_generated_ruby_file_is_syntactically_valid
    in_app(postgres: true) do |dest|
      %w[config.ru config/load.rb config/live.rb app/app.rb bin/websocket_server].each do |file|
        _out, err, status = Open3.capture3("ruby", "-c", File.join(dest, file))
        assert status.success?, "#{file}: #{err}"
      end
    end
  end

  def test_without_live_nothing_live_is_written
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest).write!

      refute File.exist?(File.join(dest, "config/live.rb"))
      refute File.exist?(File.join(dest, "public/js/monk_live"))
      assert_equal template("base/app/views/layouts/app.erb"), read(dest, "app/views/layouts/app.erb")
      assert_equal template("base/app/app.rb"), read(dest, "app/app.rb")
      refute_includes read(dest, "config/load.rb"), %(require_relative "live")
    end
  end

  def test_live_composes_with_postgres_and_auth
    in_app(auth: true) do |dest|
      load_rb = read(dest, "config/load.rb")

      assert_includes load_rb, %(require_relative "auth")
      assert_includes load_rb, %(require_relative "live")
      assert File.exist?(File.join(dest, "config/auth.rb"))
    end
  end

  # config/auth.rb used to declare its own public_url Setting (added for
  # the magic link, see docs/guides/auth.md) -- now that config/settings.rb
  # declares it unconditionally for every app (live_ws_url and
  # WS_ALLOWED_ORIGINS read it too), a --live --auth app loading both
  # files in the order config/load.rb uses them must not double-declare
  # it and raise Monk::DuplicateSettingError.
  def test_live_and_auth_together_share_one_public_url_setting_without_conflict
    require "monk/auth"

    in_app(auth: true) do |dest|
      with_settings do
        with_env("AUTH_SECRET", "s3cr3t") do
          with_env("REDIS_URL", "redis://localhost:6379/0") do
            require File.join(dest, "config/settings")
            # config/auth.rb loads the scaffolded config/persistence.rb,
            # which registers :primary -- into a registry an earlier test's
            # boot may have left frozen (FrozenError, order-dependent).
            Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
            require File.join(dest, "config/auth")
            require File.join(dest, "config/live")

            assert_equal "http://localhost:9292", Monk::Settings[:public_url]
          end
        end
      end
    end
  ensure
    Monk::Auth.reset!
    Monk::Persistence::Pg.reset! if defined?(Monk::Persistence::Pg)
    # config/live.rb configures Monk::Live; left configured, a later test
    # expecting it unconfigured fails in some random orders.
    Monk::Live.reset! if defined?(Monk::Live)
  end

  # The generated --live app as config.ru runs it: config/load.rb (settings,
  # then config/live.rb), app/app.rb, Monk.boot. GET / renders the counter
  # through app/views; POST /hit publishes through Monk::Live.patch, which
  # renders app/views/live/_hits.erb and sends it over Redis -- a wrong
  # template path or wiring would fail the request. app/app.rb goes into a
  # throwaway module so its top-level App doesn't leak into other tests.
  def test_the_generated_live_app_boots_renders_and_publishes_a_hit
    skip_unless_redis_available

    in_app do |dest|
      with_settings do
        with_env("REDIS_URL", redis_test_url) do
          Dir.chdir(dest) do
            require File.join(dest, "config/load")
            wrapper = Module.new
            load File.join(dest, "app/app.rb"), wrapper
            app = wrapper::App
            Monk.boot(app)

            _status, _headers, body = app.call(env_for("GET", "/"))
            assert_includes body.join, %(<strong id="hits">0</strong>)

            status, headers, _body = app.call(env_for("POST", "/hit"))
            assert_equal 302, status
            assert_equal "/", headers["location"]

            _status, _headers, body = app.call(env_for("GET", "/"))
            assert_includes body.join, %(<strong id="hits">1</strong>)
          end
        end
      end
    end
  ensure
    Monk::Live.reset! if defined?(Monk::Live)
    Monk::Views.reset!
    Monk::Assets.reset!
  end

  # --live --auth: a visitor's socket comes in anonymous instead of
  # refused (authenticate: :optional), so the demo's `anonymous: true`
  # "hits" topic works without logging in. The plain chat server, which
  # has no subscribe rules, stays strict.
  def test_with_auth_the_live_websocket_server_lets_visitors_in_anonymously
    in_app(auth: true) do |dest|
      server = read(dest, "bin/websocket_server")
      setup = read(dest, "SETUP.md")

      assert_includes server, "Monk::Auth.config ? :optional : false"
      assert_includes setup, "authenticate: optional"
      assert_includes setup, "**Visitors and logged-in users.**"
      refute_includes setup, "redis fan-out: on" # the live server doesn't print it
    end

    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "chat_app")
      Monk::Scaffold.new(dest, auth: true).write!

      refute_includes read(dest, "bin/websocket_server"), ":optional"
      refute_includes read(dest, "SETUP.md"), "Visitors and logged-in users"
    end
  end

  def test_live_ws_url_defaults_to_the_direct_port_in_development
    in_app do |dest|
      with_settings do
        with_monk_env("development") do
          with_env("REDIS_URL", "redis://localhost:6379/0") do
            require File.join(dest, "config/settings")
            require File.join(dest, "config/live")

            assert_equal "ws://localhost:9293", Monk::Settings[:live_ws_url]
          end
        end
      end
    end
  ensure
    Monk::Live.reset! if defined?(Monk::Live)
  end

  def test_live_ws_url_defaults_to_a_wss_path_under_public_url_outside_development
    in_app do |dest|
      with_settings do
        with_monk_env("production") do
          with_env("REDIS_URL", "redis://localhost:6379/0") do
            with_env("PUBLIC_URL", "https://chat.example.com") do
              require File.join(dest, "config/settings")
              require File.join(dest, "config/live")

              assert_equal "wss://chat.example.com/ws", Monk::Settings[:live_ws_url]
            end
          end
        end
      end
    end
  ensure
    Monk::Live.reset! if defined?(Monk::Live)
  end

  def test_websocket_server_defaults_ws_allowed_origins_to_public_url
    in_app do |dest|
      script = read(dest, "bin/websocket_server")

      assert_includes script, %(ENV.fetch("WS_ALLOWED_ORIGINS", Monk::Settings[:public_url]))
    end
  end

  def test_the_cli_accepts_live_and_the_help_documents_it
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      _out, err, status = Open3.capture3("ruby", EXE, "new", dest, "--live", "--redis")
      help, = Open3.capture2("ruby", EXE, "help")

      assert status.success?, err
      assert File.exist?(File.join(dest, "config/live.rb"))
      assert_includes help, "--live"
    end
  end

  # docs/history/plan-live-pg-fanout.md Phase 6: neither flag means there's
  # no way to tell whether this app has Postgres available, so --live no
  # longer silently defaults to Redis.
  def test_live_without_redis_or_postgres_raises_a_clear_error
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      error = assert_raises(Monk::AmbiguousLiveTransportError) { Monk::Scaffold.new(dest, live: true).write! }

      assert_match(/--redis or --postgres/, error.message)
    end
  end

  def test_the_cli_reports_the_ambiguous_transport_error_and_exits_non_zero
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      _out, err, status = Open3.capture3("ruby", EXE, "new", dest, "--live")

      refute status.success?
      assert_match(/AmbiguousLiveTransportError/, err)
      refute File.exist?(dest)
    end
  end

  def test_live_with_postgres_and_not_redis_uses_pg_fanout
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, live: true, postgres: true, redis: false).write!

      assert_equal template("live/config/live_pg.rb"), read(dest, "config/live.rb")
      refute_includes read(dest, "Gemfile"), %(gem "redis")
      refute_includes read(dest, ".env"), "REDIS_URL"
      assert_includes read(dest, "SETUP.md"), "PgFanout"
      refute_includes read(dest, "SETUP.md"), "REDIS_URL"
    end
  end

  def test_live_with_both_redis_and_postgres_uses_redis
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, live: true, postgres: true, redis: true).write!

      assert_equal template("live/config/live.rb"), read(dest, "config/live.rb")
      assert_includes read(dest, "Gemfile"), %(gem "redis")
    end
  end

  private

  # Defaults to --redis so every existing test below keeps exercising the
  # Redis transport exactly as before --live required picking one
  # explicitly (docs/history/plan-live-pg-fanout.md Phase 6); pass
  # `redis: false, postgres: true` for the PgFanout path instead.
  def in_app(**flags)
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, live: true, redis: true, **flags).write!
      yield dest
    end
  end

  def template(path) = File.read(File.join(Monk::Scaffold::TEMPLATES_DIR, path))

  def read(dest, path) = File.read(File.join(dest, path))
end
