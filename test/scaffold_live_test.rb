require_relative "test_helper"
require "tmpdir"
require "open3"
require "monk/scaffold"
require "monk/live"

# `monk new APP --live`: the Monk::Live wiring, so a fresh app has a page
# whose open tabs update when another request changes server state.
class ScaffoldLiveTest < Minitest::Test
  EXE = File.expand_path("../exe/monk", __dir__)

  def test_live_writes_the_demo_wiring_from_the_live_templates
    in_app do |dest|
      assert_equal template("live/config/live.rb"), read(dest, "config/live.rb")
      assert_equal template("live/config.ru"), read(dest, "config.ru")
      assert_equal template("live/bin/websocket_server"), read(dest, "bin/websocket_server")
      assert_equal template("live/views/index.erb"), read(dest, "views/index.erb")
      assert_equal template("live/views/live/_hits.erb"), read(dest, "views/live/_hits.erb")
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
      layout = read(dest, "views/layouts/app.erb")

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
      %w[config.ru config/live.rb bin/websocket_server].each do |file|
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
      assert_equal template("base/views/layouts/app.erb"), read(dest, "views/layouts/app.erb")
      assert_equal template("base/config.ru"), read(dest, "config.ru")
    end
  end

  def test_live_composes_with_postgres_and_auth
    in_app(auth: true) do |dest|
      config_ru = read(dest, "config.ru")

      assert_includes config_ru, %(require_relative "config/auth")
      assert_includes config_ru, %(require_relative "config/live")
      assert File.exist?(File.join(dest, "config/auth.rb"))
    end
  end

  def test_the_cli_accepts_live_and_the_help_documents_it
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")

      _out, err, status = Open3.capture3("ruby", EXE, "new", dest, "--live")
      help, = Open3.capture2("ruby", EXE, "help")

      assert status.success?, err
      assert File.exist?(File.join(dest, "config/live.rb"))
      assert_includes help, "--live"
    end
  end

  private

  def in_app(**flags)
    Dir.mktmpdir do |tmp|
      dest = File.join(tmp, "demo_app")
      Monk::Scaffold.new(dest, live: true, **flags).write!
      yield dest
    end
  end

  def template(path) = File.read(File.join(Monk::Scaffold::TEMPLATES_DIR, path))

  def read(dest, path) = File.read(File.join(dest, path))
end
