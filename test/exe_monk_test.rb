require_relative "test_helper"
require "json"
require "monk/cli"

# The `monk` command (docs/plan-scaffold.md Phase 5): monk new, monk add,
# monk add --list and monk help, in text and --json, with their exit codes
# (decision 28). Run in-process on a temp directory and a fixed clock; one
# test runs exe/monk itself.
class ExeMonkTest < Minitest::Test
  EXE = File.expand_path("../exe/monk", __dir__)
  NOW = Time.utc(2026, 10, 8, 14, 30, 0)

  # A terminal, for the prompts.
  class Terminal < StringIO
    def tty? = true
  end

  def setup
    @tmp = Dir.mktmpdir("monk-cli")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  # --- monk new ---

  def test_new_creates_a_bare_app
    code, out = monk("new", "shop")

    assert_equal 0, code
    assert out.start_with?("Created shop/ (bare Monk app).\n")
    assert_includes out, "  + config/  settings.rb, load.rb\n"
    assert_includes out, "Next:\n  cd shop\n  1. bundle install\n  2. bin/server   http://localhost:9292\n"
    assert_includes out, "  then: monk add --list   the modules you can add\n"
    assert File.exist?(File.join(@tmp, "shop/config/load.rb"))
  end

  def test_new_with_modules_adds_them_and_what_they_need
    code, out = monk("new", "shop", "--with", "auth,jobs")

    assert_equal 0, code
    assert out.start_with?("Created shop/ with auth and jobs, and postgres and mail, which they need.\n")
    %w[config/auth.rb config/jobs.rb config/persistence.rb config/mail.rb].each do |path|
      assert File.exist?(File.join(@tmp, "shop", path)), path
    end
  end

  def test_new_refuses_a_directory_that_exists
    FileUtils.mkdir_p(File.join(@tmp, "shop"))

    code, _out, err = monk("new", "shop")

    assert_equal 1, code
    assert_equal "shop already exists.\n  cd shop && monk add <module>\n\nNothing was written.\n", err
    assert_empty Dir.children(File.join(@tmp, "shop"))
  end

  def test_new_needs_a_name
    code, _out, err = monk("new")

    assert_equal 1, code
    assert_includes err, "monk new needs a name."
  end

  # docs/plan-scaffold.md decision 24: the old flags are a usage error
  # showing the same command's new form, and nothing is written.
  def test_old_flags_show_the_new_form
    {
      %w[--postgres] => "monk new shop --with postgres",
      %w[--auth --jobs] => "monk new shop --with auth,jobs",
      %w[--redis] => "monk new shop --with redis",
      %w[--live --redis] => "monk new shop --with live --transport=redis",
      %w[--auth --live --postgres] => "monk new shop --with auth,live --transport=postgres",
    }.each do |flags, new_form|
      code, _out, err = monk("new", "shop", *flags)

      assert_equal 1, code, flags.inspect
      assert_equal "monk new no longer takes module flags. The same command is now:\n  #{new_form}\n\n" \
                   "Nothing was written.\n", err
      refute File.exist?(File.join(@tmp, "shop")), flags.inspect
    end
  end

  # --- monk add ---

  def test_add_outside_an_app_says_so
    code, _out, err = monk("add", "jobs")

    assert_equal 1, code
    assert_includes err, "This isn't a Monk app (no config/load.rb here)."
  end

  def test_add_an_unknown_module
    monk("new", "shop")

    code, _out, err = monk("add", "nope", cwd: "shop")

    assert_equal 1, code
    assert_includes err, "Unknown module: nope."
  end

  def test_the_text_of_adding_jobs
    monk("new", "shop", "--with", "postgres")

    code, out = monk("add", "jobs", cwd: "shop")

    assert_equal 0, code
    assert_equal <<~TEXT, out
      Adding jobs (postgres already installed).

        + config/jobs.rb
        + bin/jobs
        + app/jobs/hello_job.rb
        + app/routes/jobs.rb             example: jobs-enqueue (commented)
        + test/jobs_test.rb
        + db/migrate/20261008143000_create_jobs_tables.{up,down}.sql
        ~ .env, .env.example             JOBS_*
        ~ SETUP.md, AGENTS.md            section: jobs

      Next:
        1. bin/setup_db
        2. bin/jobs   beside bin/server
        3. bundle exec rake test
    TEXT
  end

  def test_adding_an_installed_module
    monk("new", "shop", "--with", "jobs")

    assert_equal [0, "jobs is already installed — nothing to do.\n", ""], monk("add", "jobs", cwd: "shop")
  end

  def test_a_dry_run_writes_nothing
    monk("new", "shop", "--with", "postgres")

    code, out = monk("add", "jobs", "--dry-run", cwd: "shop")

    assert_equal 0, code
    assert out.start_with?("Would add jobs (nothing written; postgres already installed):\n")
    refute File.exist?(File.join(@tmp, "shop/config/jobs.rb"))
  end

  # A file the app already has that Monk would write: an example or test is
  # left alone, and the run goes on (decision 26).
  def test_a_test_file_the_app_already_has_is_skipped
    monk("new", "shop", "--with", "postgres")
    File.write(File.join(@tmp, "shop/test/jobs_test.rb"), "# mine\n")

    code, out = monk("add", "jobs", cwd: "shop")

    assert_equal 0, code
    assert_includes out, "  ! test/jobs_test.rb              exists and differs — left as is\n"
    assert_equal "# mine\n", File.read(File.join(@tmp, "shop/test/jobs_test.rb"))
  end

  def test_a_wiring_conflict_writes_nothing_and_exits_with_three
    monk("new", "shop", "--with", "postgres")
    File.write(File.join(@tmp, "shop/bin/jobs"), "#!/bin/sh\n")

    code, _out, err = monk("add", "jobs", cwd: "shop")

    assert_equal 3, code
    assert_includes err, "bin/jobs exists and differs, and jobs needs it to run.\n  " \
                         "Monk's version of bin/jobs: monk help jobs --file bin/jobs\n\nNothing was written.\n"
    refute File.exist?(File.join(@tmp, "shop/config/jobs.rb"))
  end

  # --- choices (decision 23) ---

  def test_without_a_terminal_a_missing_choice_is_an_error_naming_the_flag
    monk("new", "shop", "--with", "postgres,redis")

    code, _out, err = monk("add", "live", cwd: "shop")

    assert_equal 2, code
    assert_equal <<~TEXT, err
      monk add live: websocket needs a transport, and this app has both postgres and redis. Pass one:

        monk add live --transport=postgres   LISTEN/NOTIFY, nothing else to run; 8 KB per broadcast
        monk add live --transport=redis      no size limit; Redis must be running

      Nothing was written.
    TEXT
    refute File.exist?(File.join(@tmp, "shop/config/live.rb"))
  end

  def test_in_a_terminal_a_missing_choice_is_asked
    monk("new", "shop", "--with", "postgres,redis")

    code, out = monk("add", "live", cwd: "shop", stdin: Terminal.new("2\n"))

    assert_equal 0, code
    assert_includes out, "websocket needs a transport, and this app has both postgres and redis.\n\n  " \
                         "1) postgres   LISTEN/NOTIFY, nothing else to run; 8 KB per broadcast\n  " \
                         "2) redis      no size limit; Redis must be running\n\nTransport [1/2]: "
    assert_includes out, "# Using --transport=redis skips this question.\n"
    assert_includes File.read(File.join(@tmp, "shop/config/websocket.rb")), "RedisFanout"
  end

  def test_no_demo
    monk("new", "shop", "--with", "postgres")

    monk("add", "live", "--no-demo", cwd: "shop")

    refute File.exist?(File.join(@tmp, "shop/app/routes/demo_live.rb"))
  end

  # --- --json (decision 27) ---

  def test_json_for_each_status
    monk("new", "shop", "--with", "postgres,redis")

    code, out = monk("add", "jobs", "--json", cwd: "shop")
    json = JSON.parse(out)
    assert_equal [0, "ok", true], [code, json["status"], json["written"]]
    assert_equal %w[requested modules files skipped env examples services next docs].sort,
      (json.keys - %w[status written]).sort

    code, out = monk("add", "live", "--json", cwd: "shop", stdin: Terminal.new("1\n"))
    json = JSON.parse(out)
    assert_equal [2, "missing_choice", false], [code, json["status"], json["written"]], "--json never prompts"
    assert_equal({ "module" => "websocket", "option" => "transport", "values" => %w[postgres redis],
                   "reason" => "this app has both postgres and redis", }, json["choice"],)

    code, out = monk("add", "nope", "--json", cwd: "shop")
    assert_equal [1, "usage_error", "monk add --list"], [code, JSON.parse(out)["status"], JSON.parse(out)["suggestion"]]

    File.write(File.join(@tmp, "shop/bin/websocket_server"), "#!/bin/sh\n")
    code, out = monk("add", "websocket", "--transport=redis", "--json", cwd: "shop")
    assert_equal [3, "conflict"], [code, JSON.parse(out)["status"]]
    assert_equal [{ "path" => "bin/websocket_server", "module" => "websocket", "role" => "wiring",
                    "show" => "monk help websocket --file bin/websocket_server", }], JSON.parse(out)["conflicts"]
  end

  def test_new_json_names_the_app
    code, out = monk("new", "shop", "--json")

    assert_equal 0, code
    assert_equal "shop", JSON.parse(out)["app"]
  end

  # --- monk add --list ---

  def test_list_marks_what_is_installed
    monk("new", "shop", "--with", "jobs")

    code, out = monk("add", "--list", cwd: "shop")

    assert_equal 0, code
    assert out.start_with?("Modules (✓ installed)\n\n")
    assert_includes out, "  ✓ postgres    Postgres persistence and migrations\n"
    assert_includes out, "    auth        Passwordless magic-link login  (needs postgres, mail)\n"
    assert_includes out, "    websocket   WebSocket server process  (needs postgres or redis)\n"
  end

  def test_list_as_json
    code, out = monk("add", "--list", "--json")
    websocket = JSON.parse(out)["modules"].find { |row| row["name"] == "websocket" }

    assert_equal 0, code
    assert_equal({ "name" => "websocket", "summary" => "WebSocket server process", "installed" => false,
                   "needs" => [], "needs_one_of" => %w[postgres redis],
                   "options" => { "transport" => %w[postgres redis] }, }, websocket,)
  end

  # --- monk help ---

  def test_help
    %w[help --help -h].each do |command|
      code, out = monk(command)

      assert_equal 0, code
      assert_includes out, "monk new NAME [--with a,b] [options]"
      assert_includes out, "  live       Server-pushed HTML updates\n"
    end
    assert_equal 0, monk.first, "no command is help too"
  end

  def test_help_for_a_module
    code, out = monk("help", "live")

    assert_equal 0, code
    assert_includes out, "live: Server-pushed HTML updates\nNeeds: websocket\nOption --demo: on, off (default on)\n"
    assert_includes out, "  app/routes/demo_live.rb          demo\n"
  end

  def test_help_file_prints_monks_version_of_a_file
    code, out = monk("help", "jobs", "--file", "bin/jobs")
    assert_equal [0, File.read(File.join(Monk::Generator::TEMPLATES_DIR, "jobs/bin/jobs"))], [code, out]

    _code, out = monk("help", "jobs", "--file", "db/migrate/20261008143000_create_jobs_tables.up.sql")
    assert_includes out, "CREATE TABLE monk_jobs"

    code, _out, err = monk("help", "websocket", "--file", "config/websocket.rb")
    assert_equal 1, code
    assert_includes err, "monk help websocket --file config/websocket.rb --transport=postgres"
    assert_includes monk("help", "websocket", "--file", "config/websocket.rb", "--transport=redis")[1], "RedisFanout"
  end

  def test_unknown_commands_and_options
    assert_equal 1, monk("nope").first
    assert_includes monk("add", "--nope")[2], "Unknown option: --nope."
  end

  # exe/monk itself, as a user runs it.
  def test_exe_monk_runs_the_cli
    out, status = Open3.capture2e({ "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__) },
      RbConfig.ruby, "-rbundler/setup", EXE, "new", "shop", chdir: @tmp,)

    assert status.success?, out
    assert out.start_with?("Created shop/ (bare Monk app).")
  end

  private

  # [exit code, stdout, stderr].
  def monk(*args, cwd: nil, stdin: StringIO.new)
    stdout = StringIO.new
    stderr = StringIO.new
    dir = cwd ? File.join(@tmp, cwd) : @tmp
    code = Monk::CLI.new(stdin: stdin, stdout: stdout, stderr: stderr, cwd: dir, now: NOW).run(args)
    [code, stdout.string, stderr.string]
  end
end
