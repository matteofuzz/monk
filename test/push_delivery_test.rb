require_relative "test_helper"
require_relative "support/fake_s3_server"
require "monk/jobs"
require "monk/push"

# Sending (docs/plan-pwa-push.md, B4) against a push service stood up on
# loopback (FakeS3Server is a generic recorder of HTTP requests with
# canned answers): what's POSTed, and what each answer leads to. notify's
# jobs run through Monk::Jobs.drain!, each in a worker Ractor, as bin/jobs
# runs them.
class PushDeliveryTest < Minitest::Test
  include PersistenceTestHelpers
  include AuthTestHelpers
  include JobsTestHelpers
  include PushTestHelpers

  DB_NAME = :push_delivery_test_db

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    setup_push_tables(DB_NAME)
    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
    @pair = Monk::Push::Keys.generate
    Monk::Push.configure(db_name: DB_NAME, contact: "mailto:ops@shop.test", **@pair)
    @ann = sign_in("ann@shop.test")
  end

  def teardown
    @service&.stop
    if postgres_available?
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        drop_jobs_tables(conn)
        drop_push_tables(conn)
        drop_auth_tables(conn)
      end
    end
    Monk::Push.reset!
    Monk::Jobs.reset!
    Monk::Auth.reset!
    Monk::Persistence::Pg.reset!
  end

  # --- what's sent ---

  def test_a_delivered_message_is_encrypted_for_the_browser_and_signed_for_the_service
    browser = subscribe([[201, {}, ""]])
    with_log do
      outcome = Monk::Push.deliver(stored, { title: "Ann", body: "Lunch?" }, ttl: 600, urgency: "high", topic: "chat-7")

      assert_equal :delivered, outcome
    end
    request = @service.next_request

    assert_equal "POST", request.verb
    assert_equal "/push/abc", request.target
    assert_equal "aes128gcm", request.headers["content-encoding"]
    assert_equal({ "ttl" => "600", "urgency" => "high", "topic" => "chat-7" },
      request.headers.slice("ttl", "urgency", "topic"),)
    payload = decrypt(request.body.b, browser["_private_key"], browser["keys"]["p256dh"], browser["keys"]["auth"])
    assert_equal({ "title" => "Ann", "body" => "Lunch?" }, JSON.parse(payload))
    assert_vapid request.headers["authorization"], audience: "http://127.0.0.1:#{@service.port}"
    refute_nil row["last_success_at"]
  end

  def test_defaults_a_day_of_ttl_and_no_urgency_or_topic
    subscribe([[201, {}, ""]])
    with_log { Monk::Push.deliver(stored, "plain text") }

    headers = @service.next_request.headers
    assert_equal "86400", headers["ttl"]
    assert_nil headers["urgency"]
    assert_nil headers["topic"]
  end

  # --- what each answer means ---

  def test_404_and_410_mean_the_subscription_is_gone
    [404, 410].each do |status|
      subscribe([[status, {}, ""]])

      assert_equal(:gone, with_log { Monk::Push.deliver(stored, { title: "x" }) })
      assert_nil row, "#{status} deletes it"
      @service.stop
    end
  end

  def test_a_refused_vapid_header_is_final_and_logged_as_an_error
    [401, 403].each do |status|
      subscribe([[status, {}, "BadJwtToken"]])
      with_log do |dir|
        error = assert_raises(Monk::Push::RejectedError) { Monk::Push.deliver(stored, { title: "x" }) }

        assert_includes error.message, "refused the VAPID header (#{status}): BadJwtToken"
        assert_includes log_text(dir), "ERROR"
        assert_includes log_text(dir), "check VAPID_PUBLIC_KEY"
      end
      refute_nil row, "the subscription isn't the problem"
      @service.stop
    end
  end

  def test_a_refused_message_is_final
    [400, 413].each do |status|
      subscribe([[status, {}, ""]])

      assert_raises(Monk::Push::RejectedError) { with_log { Monk::Push.deliver(stored, { title: "x" }) } }
      @service.stop
    end
  end

  def test_busy_or_failing_services_are_worth_retrying
    [429, 500, 503].each do |status|
      subscribe([[status, { "retry-after" => "30" }, ""]])

      error = assert_raises(Monk::Push::DeliveryError) { with_log { Monk::Push.deliver(stored, { title: "x" }) } }
      refute_kind_of Monk::Push::RejectedError, error
      @service.stop
    end
  end

  def test_an_unreachable_service_is_worth_retrying
    port = TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
    Monk::Push.subscribe(session_token: @ann[:token],
      subscription: browser_subscription(endpoint: "http://127.0.0.1:#{port}/push/abc"),)

    error = assert_raises(Monk::Push::DeliveryError) { with_log { Monk::Push.deliver(stored, { title: "x" }) } }
    assert_includes error.message, "Errno::ECONNREFUSED"
  end

  # The endpoint's path is the browser's secret.
  def test_logs_and_errors_name_the_host_never_the_endpoint
    subscribe([[201, {}, ""], [503, {}, ""]])
    with_log do |dir|
      Monk::Push.deliver(stored, { title: "x" })
      error = assert_raises(Monk::Push::DeliveryError) { Monk::Push.deliver(stored, { title: "x" }) }

      refute_includes error.message, "/push/abc"
      refute_includes log_text(dir), "/push/abc"
      assert_includes log_text(dir), "[push] host=127.0.0.1 subscription=#{stored[:id]} status=201"
    end
  end

  def test_options_and_payloads_are_checked_before_anything_is_sent
    subscribe
    [{ ttl: -1 }, { ttl: (28 * 86_400) + 1 }, { urgency: "now" }, { topic: "has space" }, { topic: "x" * 33 }]
      .each { |options| assert_raises(ArgumentError, options.inspect) { Monk::Push.deliver(stored, "x", **options) } }
    assert_raises(Monk::Push::PayloadTooLargeError) { Monk::Push.deliver(stored, { body: "x" * 4000 }) }
    assert_equal 0, @service.requests.size
  end

  # --- notify, through jobs ---

  def test_notify_sends_one_job_per_device_and_each_reaches_its_browser
    phone = subscribe([[201, {}, ""], [201, {}, ""]])
    laptop = browser_subscription(endpoint: "http://127.0.0.1:#{@service.port}/push/laptop")
    Monk::Push.subscribe(session_token: sign_in("ann@shop.test")[:token], subscription: laptop)

    assert_equal 2, Monk::Push.notify("ann@shop.test", { title: "Ann", body: "Lunch?" }, topic: "chat-7")
    assert_equal 0, Monk::Push.notify("nobody@shop.test", { title: "x" })
    with_log { assert_equal 2, Monk::Jobs.drain! }

    bodies = 2.times.map { @service.next_request }.to_h { |request| [request.target, request.body.b] }
    { "/push/abc" => phone, "/push/laptop" => laptop }.each do |target, browser|
      payload = decrypt(bodies.fetch(target), browser["_private_key"], browser["keys"]["p256dh"],
        browser["keys"]["auth"],)
      assert_equal "Lunch?", JSON.parse(payload)["body"]
    end
  end

  def test_notify_checks_the_payload_in_the_caller
    subscribe
    assert_raises(Monk::Push::PayloadTooLargeError) { Monk::Push.notify("ann@shop.test", { body: "x" * 4000 }) }
    assert_raises(ArgumentError) { Monk::Push.notify("ann@shop.test", { title: "x" }, urgency: "now") }
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  def test_a_job_whose_subscription_stopped_counting_sends_nothing
    subscribe
    Monk::Push.notify("ann@shop.test", { title: "x" })
    Monk::Auth.revoke(@ann[:token])

    with_log { assert_equal 1, Monk::Jobs.drain! }
    assert_equal 0, @service.requests.size
  end

  def test_a_gone_subscription_is_deleted_by_its_job
    subscribe([[410, {}, ""]])
    Monk::Push.notify("ann@shop.test", { title: "x" })

    with_log { Monk::Jobs.drain! }

    assert_nil row
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  def test_a_rejected_message_fails_its_job_without_retrying
    subscribe([[403, {}, "BadJwtToken"]])
    id = Monk::Push.notify("ann@shop.test", { title: "x" }) && last_job_id

    with_log { assert_raises(Monk::Push::RejectedError) { Monk::Jobs.drain! } }

    assert_equal "failed", job_row(DB_NAME, id)["state"]
  end

  # drain! fails a job whatever it raised; bin/jobs' workers retry unless
  # the error is one of the job's never_retry classes.
  def test_a_busy_service_is_retried_and_a_rejection_is_not
    never_retry = Monk::Push::DeliveryJob.never_retry
    retried = ->(error) { never_retry.none? { |klass| error.is_a?(klass) } }

    assert retried.call(Monk::Push::DeliveryError.new("503"))
    refute retried.call(Monk::Push::RejectedError.new("403"))
    refute retried.call(Monk::Push::PayloadTooLargeError.new("too big"))
  end

  def test_sweep_runs_as_a_job
    subscribe
    Monk::Auth.revoke(@ann[:token])
    Monk::Push::Sweep.enqueue

    with_log { Monk::Jobs.drain! }

    assert_nil row
  end

  private

  # Ann's browser, subscribed at this test's push service, which answers
  # with responses in order. Returns the browser's subscription.
  def subscribe(responses = [])
    @service = FakeS3Server.new(responses: responses)
    browser = browser_subscription(endpoint: "http://127.0.0.1:#{@service.port}/push/abc")
    Monk::Push.subscribe(session_token: @ann[:token], subscription: browser)
    browser
  end

  # Ann's subscription at this test's (latest) push service.
  def stored
    subscriptions = Monk::Push.subscriptions("ann@shop.test")
    return subscriptions.first unless @service

    subscriptions.find { |sub| sub[:endpoint].include?(":#{@service.port}/") }
  end

  def row
    Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
      conn.exec_params("SELECT * FROM push_subscriptions WHERE endpoint LIKE $1", ["%:#{@service.port}/%"]).first
    end
  end

  def last_job_id
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| Integer(conn.exec("SELECT max(id) FROM monk_jobs").getvalue(0, 0)) }
  end

  def log_text(dir) = Dir[File.join(dir, "*.log")].map { |file| File.read(file) }.join

  def assert_vapid(header, audience:)
    jwt, public_key = header.match(/\Avapid t=([^,]+), k=(\S+)\z/).captures
    head, claims, signature = jwt.split(".")

    assert_equal @pair[:public_key], public_key
    assert_equal audience, JSON.parse(Monk::Push::Base64Url.decode(claims))["aud"]
    assert verifies?(public_key, "#{head}.#{claims}", Monk::Push::Base64Url.decode(signature))
  end
end
