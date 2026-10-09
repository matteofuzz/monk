require_relative "test_helper"

# Monk::Mail is configured, and with .env.test's MAIL_URL=log:// a message
# lands in log/test.log instead of being sent: SETUP.md, mail.
class MailTest < Minitest::Test
  def test_a_message_is_delivered_to_the_test_log
    subject = "Mail check #{rand(1_000_000)}"

    Monk::Mail.deliver(to: "ann@example.test", subject: subject, text: "Hello")

    assert_includes File.read(File.expand_path("../log/test.log", __dir__)), subject.inspect
  end
end
