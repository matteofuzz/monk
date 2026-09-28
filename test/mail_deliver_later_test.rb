require_relative "test_helper"
require_relative "support/fake_smtp_server"
require "monk/mail"
require "monk/mail/later"
require "monk/jobs/runtime"
require "monk/persistence/pg"

# Monk::Mail.deliver_later and Monk::Mail::DeliveryJob (ADR 0014,
# docs/history/plan-jobs.md Phase 10 step 30), against a fake SMTP server
# and the real job queue.
class MailDeliverLaterTest < Minitest::Test
  include PersistenceTestHelpers
  include JobsTestHelpers

  DB_NAME = :mail_deliver_later_test_db
  PROCESS_ID = 1
  FROM = "App <no-reply@app.test>".freeze

  def setup
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    Monk::Mail.reset!
    skip_unless_postgres_available

    setup_jobs_tables(DB_NAME)
    Monk::Jobs.configure(db_name: DB_NAME)
  end

  def teardown
    @server&.stop
    Monk::Persistence::Pg.checkout(DB_NAME) { |conn| drop_jobs_tables(conn) } if postgres_available?
    Monk::Persistence::Pg.reset!
    Monk::Jobs.reset!
    Monk::Mail.reset!
  end

  def test_deliver_later_enqueues_on_the_mailers_queue_and_sends_nothing_yet
    configure_mail

    id = Monk::Mail.deliver_later(to: "ann@example.test", subject: "Your receipt", text: "Thanks!")

    job = job_row(DB_NAME, id)
    assert_equal "mailers", job["queue"]
    assert_equal "Monk::Mail::DeliveryJob", job["job_class"]
    assert_empty @server.sessions
  end

  def test_the_job_sends_the_message_as_given
    configure_mail
    Monk::Mail.deliver_later(
      to: ["Ann <ann@example.test>", "bob@example.test"], subject: "Your receipt",
      text: "Thanks!", html: "<p>Thanks!</p>", reply_to: "support@app.test",
    )

    assert_equal 1, Monk::Jobs.drain!

    session = @server.last_session
    assert_equal "no-reply@app.test", session.mail_from
    assert_equal ["ann@example.test", "bob@example.test"], session.rcpt_to
    assert_includes session.data, "Subject: Your receipt"
    assert_includes session.data, "Reply-To: support@app.test"
    assert_includes session.data, "multipart/alternative"
  end

  # The job stores the sender it was enqueued with, resolved against
  # configure's from: at that moment, as deliver would have used then.
  def test_a_missing_from_is_resolved_when_enqueueing
    configure_mail

    id = Monk::Mail.deliver_later(to: "ann@example.test", subject: "Hi", text: "Hi")

    assert_equal FROM, JSON.parse(job_row(DB_NAME, id)["args"]).first["from"]
  end

  def test_bad_input_raises_in_the_caller_and_enqueues_nothing
    configure_mail

    assert_raises(Monk::Mail::InvalidMessageError) do
      Monk::Mail.deliver_later(to: "ann@example.test\r\nBcc: all@example.test", subject: "Hi", text: "Hi")
    end
    assert_raises(Monk::Mail::InvalidMessageError) { Monk::Mail.deliver_later(to: "ann@example.test", subject: "Hi") }
    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  def test_deliver_later_before_configure_names_the_fix
    error = assert_raises(Monk::Mail::NotConfiguredError) do
      Monk::Mail.deliver_later(to: "ann@example.test", subject: "Hi", text: "Hi")
    end

    assert_match(/Monk::Mail\.configure/, error.message)
  end

  def test_deliver_later_takes_wait
    configure_mail

    id = Monk::Mail.deliver_later(to: "ann@example.test", subject: "Hi", text: "Hi", wait: 3600)

    assert_equal "scheduled", job_row(DB_NAME, id)["state"]
  end

  # The email commits or rolls back with the app's own writes.
  def test_deliver_later_on_the_callers_connection_rolls_back_with_it
    configure_mail

    assert_raises(PG::Error) do
      Monk::Persistence::Pg.checkout(DB_NAME) do |conn|
        conn.transaction do
          Monk::Mail.deliver_later(to: "ann@example.test", subject: "Hi", text: "Hi", conn: conn)
          raise PG::Error, "the order didn't save"
        end
      end
    end

    assert_equal 0, count_rows(DB_NAME, "monk_jobs")
  end

  # 550: the server refused for good. Another attempt can't help.
  def test_a_permanent_smtp_refusal_fails_the_job_at_once
    configure_mail(reject: { rcpt: "550 5.1.1 no such mailbox" })
    id = Monk::Mail.deliver_later(to: "nobody@example.test", subject: "Hi", text: "Hi")

    run_as_a_worker

    job = job_row(DB_NAME, id)
    assert_equal "failed", job["state"]
    assert_match(/\AMonk::Mail::PermanentDeliveryError: .*550/, job["last_error"])
  end

  # 450: try again later, which is what the queue is for.
  def test_a_temporary_smtp_refusal_is_retried
    configure_mail(reject: { rcpt: "450 4.2.1 mailbox busy, try later" })
    id = Monk::Mail.deliver_later(to: "busy@example.test", subject: "Hi", text: "Hi")

    run_as_a_worker

    job = job_row(DB_NAME, id)
    assert_equal "scheduled", job["state"]
    assert_match(/\AMonk::Mail::DeliveryError: .*450/, job["last_error"])
  end

  def test_a_relay_that_isnt_there_is_retried
    closed_port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    Monk::Mail.configure(url: "smtp://127.0.0.1:#{closed_port}?starttls=never", from: FROM)
    id = Monk::Mail.deliver_later(to: "ann@example.test", subject: "Hi", text: "Hi")

    run_as_a_worker

    assert_equal "scheduled", job_row(DB_NAME, id)["state"]
  end

  # Still a DeliveryError, so code that rescues DeliveryError around a
  # synchronous deliver keeps catching both kinds.
  def test_permanent_delivery_error_is_a_delivery_error
    assert_operator Monk::Mail::PermanentDeliveryError, :<, Monk::Mail::DeliveryError
  end

  private

  def configure_mail(reject: {})
    @server = FakeSMTPServer.new(reject: reject)
    Monk::Mail.configure(url: "smtp://127.0.0.1:#{@server.port}?starttls=never", from: FROM)
  end

  # The job process's own handling of one claimed job: claim, run, then
  # finish or fail with the worker's retry rules. drain! can't show this,
  # since it retries nothing by design.
  def run_as_a_worker
    Monk.freeze!
    claim = Monk::Jobs.adapter.claim("mailers", PROCESS_ID)
    Monk::Jobs::Worker.perform(Monk::Jobs.adapter, PROCESS_ID, claim)
  end
end
