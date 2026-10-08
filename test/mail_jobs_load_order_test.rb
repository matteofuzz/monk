require_relative "test_helper"
require "open3"

# Monk::Mail.deliver_later is loaded by whichever of monk/mail and
# monk/jobs is required second (docs/adr/0017), so an app gets it from
# its config files in any order, with no `require "monk/mail/later"` of
# its own. Each case runs in a fresh Ruby: this suite has loaded both.
class MailJobsLoadOrderTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  PROBES = {
    "deliver_later" => "print Monk::Mail.respond_to?(:deliver_later)",
    "p_jobs" => "print Monk::Mail.respond_to?(:deliver_later), ' ', Monk.const_defined?(:Jobs)",
    "p_mail" => "print Monk.const_defined?(:Mail)",
  }.freeze

  def test_mail_then_jobs_defines_deliver_later
    assert_equal "true", probe(%w[monk/mail monk/jobs])
  end

  def test_jobs_then_mail_defines_deliver_later
    assert_equal "true", probe(%w[monk/jobs monk/mail])
  end

  # What config/jobs.rb in apps scaffolded before ADR 0017 still requires.
  def test_requiring_monk_mail_later_still_works
    assert_equal "true", probe(%w[monk/mail/later])
  end

  def test_mail_alone_doesnt_load_jobs
    assert_equal "false false", probe(%w[monk/mail], "p_jobs")
  end

  def test_jobs_alone_doesnt_load_mail
    assert_equal "false", probe(%w[monk/jobs], "p_mail")
  end

  private

  def probe(features, probe = "deliver_later")
    script = features.map { |feature| "require #{feature.inspect}" }.push(PROBES.fetch(probe)).join("; ")
    out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", LIB, "-e", script)
    assert status.success?, err
    refute_match(/circular require/, err)
    out
  end
end
