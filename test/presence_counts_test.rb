require_relative "test_helper"
require "monk/presence"

# The per-process counts (ADR 0019, "Counting, no query per connect"):
# sockets reported by their own Ractors, read back as the subjects that
# changed since the last take.
class PresenceCountsTest < Minitest::Test
  def setup
    @counts = Monk::Presence::Counts.new(start_visible: true)
  end

  def test_nothing_changed_takes_empty_lists
    assert_equal({ online: [], away: [], gone: [] }, @counts.take)
  end

  def test_an_opened_socket_is_online_and_taken_once
    @counts.open(:s1, "u:1")

    assert_equal({ online: ["u:1"], away: [], gone: [] }, @counts.take)
    assert_equal({ online: [], away: [], gone: [] }, @counts.take)
  end

  def test_a_socket_that_starts_hidden_is_away_until_visible
    counts = Monk::Presence::Counts.new(start_visible: false)
    counts.open(:s1, "u:1")
    assert_equal ["u:1"], counts.take[:away]

    counts.visible(:s1, true)
    assert_equal ["u:1"], counts.take[:online]
    counts.visible(:s1, false)
    assert_equal ["u:1"], counts.take[:away]
  end

  def test_a_subject_is_online_while_any_of_its_sockets_is_visible
    @counts.open(:s1, "u:1")
    @counts.open(:s2, "u:1")
    @counts.take

    @counts.visible(:s1, false)
    assert_equal({ online: ["u:1"], away: [], gone: [] }, @counts.take)
    @counts.visible(:s2, false)
    assert_equal({ online: [], away: ["u:1"], gone: [] }, @counts.take)
  end

  def test_a_subject_is_gone_when_its_last_socket_closes
    @counts.open(:s1, "u:1")
    @counts.open(:s2, "u:1")
    @counts.take

    @counts.close(:s1)
    assert_equal({ online: ["u:1"], away: [], gone: [] }, @counts.take)
    @counts.close(:s2)
    assert_equal({ online: [], away: [], gone: ["u:1"] }, @counts.take)
  end

  def test_a_close_and_reopen_between_takes_is_open
    @counts.open(:s1, "u:1")
    @counts.take
    @counts.close(:s1)
    @counts.open(:s2, "u:1")

    assert_equal({ online: ["u:1"], away: [], gone: [] }, @counts.take)
  end

  def test_a_late_or_repeated_report_changes_nothing
    @counts.open(:s1, "u:1")
    @counts.close(:s1)
    @counts.close(:s1)
    @counts.visible(:s1, true)

    assert_equal({ online: [], away: [], gone: ["u:1"] }, @counts.take)
    assert_equal({ online: [], away: [], gone: [] }, @counts.take)
  end

  def test_all_is_every_subject_with_a_socket
    @counts.open(:s1, "u:1")
    @counts.open(:s2, "u:2")
    @counts.visible(:s2, false)
    @counts.open(:s3, "u:3")
    @counts.close(:s3)

    assert_equal({ online: ["u:1"], away: ["u:2"] }, @counts.all)
  end

  # What Server.serve does: each socket reports from its own Ractor, keyed
  # by it, and a report is a send, so it never waits.
  def test_sockets_report_from_their_own_ractors
    counts = @counts
    ractors = Array.new(3) do |i|
      Ractor.new(counts, "u:#{i}") do |c, subject|
        c.open(Ractor.current, subject)
        c.close(Ractor.current) if subject == "u:2"
      end
    end
    ractors.each(&:join)

    assert_equal({ online: ["u:0", "u:1"], away: [], gone: ["u:2"] }, counts.take.transform_values(&:sort))
  end
end
