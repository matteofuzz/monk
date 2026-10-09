require_relative "test_helper"
require "monk/auth"
require "monk/jobs"
require "json"

# Monk::Auth::SendLoginLink (docs/adr/0014, docs/adr/0017): the job
# carries only the email, the token is created and sent inside the job,
# and the link it sends works.
class AuthSendLoginLinkTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers
  include JobsTestHelpers

  DB_NAME = :auth_send_login_link_test_db

  # deliver: has to be shareable (the job runs in its own Ractor), so it
  # reports the link through the log rather than into a local variable.
  module Deliver
    TO_LOG = ->(email:, link:, token:) { Monk::Log.info("LINK #{email} #{link} #{token.length}") }
  end

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    setup_auth_tables(DB_NAME)
    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
  end

  def teardown
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_jobs_tables(conn)
        drop_auth_tables(conn)
      end
    end
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    Monk::Auth.reset!
  end

  def test_runs_on_the_mailers_queue_with_three_attempts
    assert_equal "mailers", Monk::Auth::SendLoginLink.queue
    assert_equal 3, Monk::Auth::SendLoginLink.max_attempts
  end

  def test_queues_only_the_email_and_sends_a_working_link_when_it_runs
    with_app(callback_path: "/login/verify") do |log_dir|
      Monk::Auth::SendLoginLink.enqueue("ann@example.test")

      assert_equal ["ann@example.test"], JSON.parse(queued_args), "only the email is queued"
      assert_equal 0, count_rows("login_tokens"), "no token exists until the job runs"

      assert_equal 1, Monk::Jobs.drain!

      line = File.read(File.join(log_dir, "test.log"))[/LINK ann@example\.test (\S+) \d+/]
      refute_nil line, "deliver: was called with the link"
      link = line.split[2]
      assert link.start_with?("https://app.example/login/verify/"), link
      assert_equal "ann@example.test", Monk::Auth.redeem(link.split("/").last)&.fetch(:subject)
    end
  end

  private

  def with_app(**auth_options)
    with_log do |log_dir|
      with_settings do
        with_env("PUBLIC_URL", "https://app.example") do
          Monk::Settings.configure { optional :public_url, default: "http://localhost:9292" }
          Monk::Auth.configure(
            db_name: DB_NAME, secret: "s3cr3t", login_ttl: 600, session_ttl: 1_209_600,
            deliver: Deliver::TO_LOG, **auth_options,
          )
          yield log_dir
        end
      end
    end
  end

  def queued_args
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT args::text FROM monk_job_payloads").getvalue(0, 0) }
  end

  def count_rows(table)
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| conn.exec("SELECT count(*) FROM #{table}").getvalue(0, 0).to_i }
  end
end
