require_relative "test_helper"
require "monk/live"

class LivePolicyTest < Minitest::Test
  # Class-body scope, not inline: self here is a Class, always
  # Ractor.shareable?, which is what authorize's block requires (same
  # constraint as Server#run and StateRactor#update).
  OWN_CONTACTS = proc { |subject, topic| topic == "contacts:#{subject}" }
  ALLOW = proc { |_subject, _topic| true }
  DENY = proc { |_subject, _topic| false }
  RAISES = proc { |_subject, _topic| raise "boom" }
  TRUTHY = proc { |_subject, _topic| :yes }
  RETURNS_NIL = proc { |_subject, _topic| }

  def teardown
    Monk::Live.reset!
  end

  def test_everything_is_denied_when_no_rule_is_declared
    refute Monk::Live.authorized?("7", "contacts:7")
  end

  def test_a_glob_rule_matches_by_prefix_and_its_block_decides
    Monk::Live.authorize("contacts:*", &OWN_CONTACTS)

    assert Monk::Live.authorized?("7", "contacts:7")
    refute Monk::Live.authorized?("7", "contacts:8")
  end

  def test_a_topic_no_rule_matches_is_denied
    Monk::Live.authorize("contacts:*", &ALLOW)

    refute Monk::Live.authorized?("7", "chat:1")
  end

  def test_an_exact_pattern_matches_only_that_topic
    Monk::Live.authorize("lobby", &ALLOW)

    assert Monk::Live.authorized?("7", "lobby")
    refute Monk::Live.authorized?("7", "lobby:2")
  end

  def test_the_first_matching_rule_decides
    Monk::Live.authorize("chat:secret", &DENY)
    Monk::Live.authorize("chat:*", &ALLOW)

    refute Monk::Live.authorized?("7", "chat:secret")
    assert Monk::Live.authorized?("7", "chat:general")
  end

  def test_an_anonymous_subject_is_denied_without_calling_the_block
    Monk::Live.authorize("contacts:*", &ALLOW)

    refute Monk::Live.authorized?(nil, "contacts:")
  end

  def test_a_rule_declared_anonymous_lets_an_anonymous_subject_through
    Monk::Live.authorize("public:*", anonymous: true, &ALLOW)

    assert Monk::Live.authorized?(nil, "public:news")
  end

  def test_a_block_that_raises_fails_closed
    Monk::Live.authorize("x:*", &RAISES)

    refute Monk::Live.authorized?("7", "x:1")
  end

  def test_a_truthy_non_boolean_result_allows_and_nil_denies
    Monk::Live.authorize("yes:*", &TRUTHY)
    Monk::Live.authorize("no:*", &RETURNS_NIL)

    assert Monk::Live.authorized?("7", "yes:1")
    refute Monk::Live.authorized?("7", "no:1")
  end

  def test_authorize_rejects_an_unshareable_block_with_a_precise_error
    captured = +"state"

    error = assert_raises(Monk::UnshareableBlockError) do
      Monk::Live.authorize("x:*") { |_subject, _topic| captured }
    end
    assert_match(/not Ractor-shareable/, error.message)
  end

  def test_authorize_needs_a_block
    assert_raises(ArgumentError) { Monk::Live.authorize("x:*") }
  end

  def test_authorize_rejects_a_blank_or_misplaced_wildcard_pattern
    ["", "  ", "a*b", "**", nil].each do |pattern|
      assert_raises(ArgumentError, pattern.inspect) { Monk::Live.authorize(pattern, &ALLOW) }
    end
  end

  def test_rules_are_shareable_and_decide_from_a_non_main_ractor
    Monk::Live.authorize("contacts:*", &OWN_CONTACTS)

    assert Ractor.shareable?(Monk::Live.rules)
    assert Ractor.new { Monk::Live.authorized?("7", "contacts:7") }.value
  end
end
