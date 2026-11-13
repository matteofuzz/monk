require_relative "test_helper"

# Monk::Presence reads each person's status from the tables its migration
# made (bin/setup_db). Someone with no page open is offline, never seen.
# SETUP.md, presence.
class PresenceTest < Minitest::Test
  def test_someone_with_no_page_open_is_offline
    subject = "presence-check-#{rand(1_000_000)}@example.test"

    assert_equal({ subject => { status: :offline, last_seen_at: nil } }, Monk::Presence.status([subject]))
    refute Monk::Presence.online?(subject)
  end
end
