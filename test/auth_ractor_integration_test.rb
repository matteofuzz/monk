require_relative "test_helper"
require "json"
require "monk/auth"

class AuthRactorIntegrationTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers

  DB_NAME = :auth_ractor_integration_db

  def setup
    Monk::Persistence::Pg.reset!
    setup_auth_tables(DB_NAME)

    # Real end-to-end boot, exactly as a real app would: this is what
    # actually freezes Monk::Auth's config (and Persistence::Pg's registry,
    # and LoginToken/Session's own db_name/table_name) so they're readable
    # from a real worker Ractor at all -- mirrors
    # persistence_ractor_integration_test.rb's identical setup.
    app = Class.new(Monk::Base) { get("/x") { "hi" } }
    app.freeze!
  end

  def teardown
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_auth_tables(conn) }
    end
    Monk::Persistence::Pg.reset!
    Monk::Auth.reset!
  end

  def test_n_real_ractors_redeeming_the_same_login_token_concurrently_exactly_one_wins
    raw = Monk::Auth.request_login("a@b.com")
    ractor_count = 8

    results = Array.new(ractor_count) do
      Ractor.new(Monk::Auth, raw) { |auth, token| auth.redeem(token) }
    end.map(&:value)

    assert_equal 1, results.compact.size
    assert_equal ractor_count - 1, results.count(&:nil?)
    session_rows = Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM sessions WHERE subject = $1", ["a@b.com"]).to_a
    end
    assert_equal 1, session_rows.size
  end

  def test_n_real_ractors_verifying_distinct_session_tokens_concurrently_all_succeed_independently
    ractor_count = 8
    sessions = (1..ractor_count).map { |i| Monk::Auth.redeem(Monk::Auth.request_login("user#{i}@b.com")) }

    results = sessions.map do |session|
      Ractor.new(Monk::Auth, session[:token]) { |auth, token| auth.verify(token) }
    end.map(&:value)

    assert_equal (1..ractor_count).map { |i| "user#{i}@b.com" }, results
  end

  def test_full_magic_link_round_trip_from_inside_a_real_worker_ractor
    app = Class.new(Monk::Base) do
      post("/auth/request/:email") do |ctx|
        token = Monk::Auth.request_login(ctx.params[:email])
        ctx.json(token: token)
      end

      get("/auth/callback/:token") do |ctx|
        session = Monk::Auth.redeem(ctx.params[:token])
        ctx.halt(401) unless session
        ctx.json(token: session[:token], subject: session[:subject])
      end

      get("/me") do |ctx|
        ctx.json(subject: ctx.require_user!)
      end
    end
    app.freeze!

    result = Ractor.new(app) do |a|
      _, _, request_body = a.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/auth/request/a@b.com")
      raw_token = JSON.parse(request_body.join)["token"]

      _, _, callback_body = a.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/auth/callback/#{raw_token}")
      session_token = JSON.parse(callback_body.join)["token"]

      me_status, _, me_body = a.call(
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/me",
        "HTTP_AUTHORIZATION" => "Bearer #{session_token}",
      )

      [me_status, JSON.parse(me_body.join)["subject"]]
    end.value

    assert_equal [200, "a@b.com"], result
  end

  # Regression: rqrcode (used by log_dev_link) has several ordinary,
  # unfrozen top-level constants of its own -- reading one of those from
  # a worker Ractor raised Ractor::IsolationError the first time this ran
  # inside a real request (confirmed live in a real app under Kino, not
  # just this suite). freeze_rqrcode! (called from Monk::Auth's own
  # freeze_registry!, alongside @config) is the fix; this exercises it
  # the same way the tests above exercise Auth's other Ractor-sensitive
  # paths -- a real app.freeze! followed by a real Ractor.new(app).call,
  # not a direct method call from the main (test-runner) Ractor, which
  # would never have caught this.
  def test_log_dev_link_works_from_inside_a_real_worker_ractor
    with_log do
      with_settings do
        with_monk_env("development") do
          app = Class.new(Monk::Base) do
            post("/auth/request/:email") do |ctx|
              token = Monk::Auth.request_login(ctx.params[:email])
              Monk::Auth.log_dev_link("http://x/auth/callback/#{token}", subject: ctx.params[:email])
              ctx.json(ok: true)
            end
          end
          app.freeze!

          status, = Ractor.new(app) do |a|
            a.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/auth/request/a@b.com")
          end.value

          assert_equal 200, status
        end
      end
    end
  end
end
