require_relative "test_helper"
require "monk/live"

# What a batch rule's block was called with, in the calling thread: the
# blocks are shareable procs, so they record through this module, not a
# captured local.
module BatchCalls
  def self.record(topics) = (Thread.current[:batch_calls] ||= []) << topics
  def self.all = Thread.current[:batch_calls] || []
  def self.clear = Thread.current[:batch_calls] = nil
end

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
  RETURNS_ARRAY = proc { |_subject, _topic| [] }

  # Batch blocks: |subject, topics| -> the allowed ones.
  EVEN = proc do |_subject, topics|
    BatchCalls.record(topics)
    topics.select { |topic| topic.delete_prefix("p:").to_i.even? }
  end
  EVEN_SET = proc { |_subject, topics| Set.new(topics.select { |topic| topic.delete_prefix("p:").to_i.even? }) }
  MORE_THAN_ASKED = proc { |_subject, topics| [*topics, "p:99", "other:1", :"p:1"] }
  BATCH_NIL = proc { |_subject, _topics| }
  BATCH_FALSE = proc { |_subject, _topics| false }
  BATCH_TRUE = proc { |_subject, _topics| true }
  BATCH_HASH = proc { |_subject, topics| topics.to_h { |topic| [topic, true] } }
  BATCH_RAISES = proc { |_subject, _topics| raise "boom" }
  OWN_IN_BATCH = proc { |subject, topics| topics.select { |topic| topic == "p:#{subject}" } }

  def setup
    BatchCalls.clear
  end

  def teardown
    Monk::Live.reset!
  end

  def allowed(subject, topics) = Monk::Live::Policy.allowed_topics(Monk::Live.rules, subject, topics)

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

  # For a rule that lets everyone in (the scaffold's development-only
  # demo): a block written at the top of config/live.rb isn't shareable.
  def test_allow_all_is_a_shareable_block_that_lets_everyone_in
    assert Ractor.shareable?(Monk::Live::ALLOW_ALL)

    Monk::Live.authorize("demo:hits", anonymous: true, &Monk::Live::ALLOW_ALL)

    assert Monk::Live.authorized?(nil, "demo:hits")
    assert Monk::Live.authorized?("7", "demo:hits")
    refute Monk::Live.authorized?(nil, "demo:other")
  end

  def test_a_batch_rule_is_called_once_with_only_the_topics_it_matches_first
    Monk::Live.authorize("p:secret", &DENY)
    Monk::Live.authorize("p:*", batch: true, &EVEN)
    Monk::Live.authorize("q:*", &ALLOW)

    result = allowed("7", %w[p:1 q:1 p:2 p:secret p:4 p:2 r:1])

    assert_equal Set["p:2", "p:4", "q:1"], result
    assert_equal [%w[p:1 p:2 p:4]], BatchCalls.all
  end

  def test_a_batch_rule_above_a_single_topic_rule_takes_the_topics_it_matches
    Monk::Live.authorize("p:*", batch: true, &EVEN)
    Monk::Live.authorize("p:1", &ALLOW)

    assert_equal Set["p:2"], allowed("7", %w[p:1 p:2])
    assert_equal [%w[p:1 p:2]], BatchCalls.all
  end

  def test_a_batch_rule_is_not_called_when_no_topic_matches_it
    Monk::Live.authorize("p:*", batch: true, &EVEN)
    Monk::Live.authorize("q:*", &ALLOW)

    assert_equal Set["q:1"], allowed("7", %w[q:1])
    assert_empty BatchCalls.all
  end

  def test_a_batch_rule_may_return_an_array_or_a_set
    Monk::Live.authorize("p:*", batch: true, &EVEN_SET)

    assert_equal Set["p:2"], allowed("7", %w[p:1 p:2])
  end

  def test_a_returned_topic_that_was_not_asked_for_is_ignored
    Monk::Live.authorize("p:*", batch: true, &MORE_THAN_ASKED)

    assert_equal Set["p:1", "p:2"], allowed("7", %w[p:1 p:2])
  end

  def test_nil_or_false_from_a_batch_rule_allows_none
    Monk::Live.authorize("n:*", batch: true, &BATCH_NIL)
    Monk::Live.authorize("f:*", batch: true, &BATCH_FALSE)

    assert_empty allowed("7", %w[n:1 f:1])
  end

  # true must never mean "all": a batch rule says which topics.
  def test_any_other_result_from_a_batch_rule_denies_them_all_and_is_logged
    Monk::Live.authorize("t:*", batch: true, &BATCH_TRUE)
    Monk::Live.authorize("h:*", batch: true, &BATCH_HASH)

    result, log = logged { allowed("7", %w[t:1 t:2 h:1]) }

    assert_empty result
    assert_match(/ERROR Monk::Live: denied 2 topics \(rule t:\*\): its block returned TrueClass/, log)
    assert_match(/denied 1 topic \(rule h:\*\): its block returned Hash/, log)
  end

  def test_a_batch_block_that_raises_denies_its_whole_group_and_is_logged
    Monk::Live.authorize("p:*", batch: true, &BATCH_RAISES)
    Monk::Live.authorize("q:*", &ALLOW)

    result, log = logged { allowed("7", %w[p:1 p:2 q:1]) }

    assert_equal Set["q:1"], result
    assert_match(/denied 2 topics \(rule p:\*\): its block raised RuntimeError: boom/, log)
  end

  def test_a_single_topic_block_that_raises_is_logged
    Monk::Live.authorize("x:*", &RAISES)

    result, log = logged { Monk::Live.authorized?("7", "x:1") }

    refute result
    assert_match(/denied x:1 \(rule x:\*\): its block raised RuntimeError: boom/, log)
  end

  # A batch block declared without batch: true would get a String and
  # return an Array, truthy even when empty: it must not let anything in.
  def test_a_single_topic_rule_returning_a_collection_denies_and_says_why
    Monk::Live.authorize("a:*", &RETURNS_ARRAY)

    result, log = logged { Monk::Live.authorized?("7", "a:1") }

    refute result
    assert_match(/denied a:1 \(rule a:\*\): its block returned Array: .*needs batch: true/, log)
  end

  def test_an_anonymous_subject_is_denied_a_batch_rule_without_calling_the_block
    Monk::Live.authorize("p:*", batch: true, &EVEN)

    assert_empty allowed(nil, %w[p:2])
    assert_empty BatchCalls.all
  end

  def test_a_batch_rule_declared_anonymous_lets_an_anonymous_subject_through
    Monk::Live.authorize("p:*", anonymous: true, batch: true, &EVEN)

    assert_equal Set["p:2"], allowed(nil, %w[p:1 p:2])
  end

  def test_authorized_asks_a_batch_rule_about_one_topic
    Monk::Live.authorize("p:*", batch: true, &OWN_IN_BATCH)

    assert Monk::Live.authorized?("7", "p:7")
    refute Monk::Live.authorized?("7", "p:8")
  end

  def test_the_topics_a_block_gets_are_frozen
    Monk::Live.authorize("p:*", batch: true, &EVEN)

    allowed("7", [+"p:1", +"p:2"])

    assert BatchCalls.all.first.frozen?
    assert BatchCalls.all.first.all?(&:frozen?)
  end

  def test_batch_must_be_true_or_false
    assert_raises(ArgumentError) { Monk::Live.authorize("p:*", batch: "yes", &EVEN) }
  end

  def test_a_batch_rule_decides_from_a_non_main_ractor
    Monk::Live.authorize("p:*", batch: true, &OWN_IN_BATCH)

    assert Ractor.shareable?(Monk::Live.rules)
    assert_equal Set["p:7"], Ractor.new { Monk::Live::Policy.allowed_topics(Monk::Live.rules, "7", %w[p:7 p:8]) }.value
  end

  private

  # What the block returns, and what Monk::Log wrote meanwhile.
  def logged
    with_log do |dir|
      with_settings do
        Monk::Settings.freeze_registry!
        Monk::Log.freeze_registry!
        result = yield
        [result, File.read(File.join(dir, "test.log"))]
      end
    end
  end
end
