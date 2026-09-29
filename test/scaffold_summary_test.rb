require_relative "test_helper"
require "monk/scaffold"

# What `monk new` prints about the flags it resolved: which were implied,
# by which flag, and which combinations change what's generated -- so the
# rule "implied when there's one right answer, required when there's a
# choice" is visible at the moment it applies.
class ScaffoldSummaryTest < Minitest::Test
  def test_the_base_skeleton
    assert_equal ["Flags: none (the base skeleton)."], summary
  end

  def test_flags_that_imply_nothing_are_listed_as_given
    assert_equal ["Flags: --postgres --redis."], summary(postgres: true, redis: true)
  end

  def test_implied_flags_say_which_flag_needed_them
    assert_equal [
      "Flags: --auth --jobs, which also turned on:",
      "  --postgres  (needed by --auth, --jobs)",
      "  --mail      (needed by --auth)",
      "Together they also generate:",
      "  --auth + --jobs  app/jobs/send_login_link.rb: login links are sent from a job",
      "  --mail + --jobs  config/jobs.rb loads Monk::Mail.deliver_later; JOBS_QUEUES serves mailers first",
    ], summary(auth: true, jobs: true)
  end

  # Passed explicitly, a flag isn't reported as implied even when another
  # flag would have turned it on anyway.
  def test_a_flag_passed_explicitly_isnt_reported_as_implied
    assert_equal ["Flags: --postgres --jobs."], summary(postgres: true, jobs: true)
  end

  def test_live_says_which_transport_it_uses
    assert_includes summary(live: true, postgres: true),
      "  --live + --postgres  config/live.rb fans out over Postgres (Monk::WebSocket::PgFanout)"
    assert_includes summary(live: true, redis: true),
      "  --live + --redis  config/live.rb fans out over Redis (Monk::WebSocket::RedisFanout)"
  end

  def test_live_with_both_transports_says_redis_won
    assert_includes summary(live: true, redis: true, postgres: true),
      "  --live + --redis  config/live.rb fans out over Redis (Monk::WebSocket::RedisFanout; " \
      "--redis wins over --postgres)"
  end

  private

  def summary(**flags)
    Monk::Scaffold.new("/tmp/never-written", **flags).summary
  end
end
