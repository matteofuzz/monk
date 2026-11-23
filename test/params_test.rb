require_relative "test_helper"

class ParamsTest < Minitest::Test
  def parse(string) = Monk::Params.parse(string)

  def test_plain_pairs_with_symbol_keys
    assert_equal({ a: "1", b: "two words" }, parse("a=1&b=two+words"))
  end

  def test_empty_or_nil_is_an_empty_hash
    assert_equal({}, parse(""))
    assert_equal({}, parse(nil))
  end

  def test_a_repeated_plain_key_keeps_the_last_value
    assert_equal({ a: "2" }, parse("a=1&a=2"))
  end

  def test_nested_hashes
    assert_equal({ user: { name: "Ann", address: { city: "Rome" } } },
      parse("user[name]=Ann&user[address][city]=Rome"),)
  end

  def test_arrays
    assert_equal({ tags: %w[a b] }, parse("tags[]=a&tags[]=b"))
  end

  def test_an_array_inside_a_hash
    assert_equal({ post: { tags: %w[a b] } }, parse("post[tags][]=a&post[tags][]=b"))
  end

  def test_percent_encoded_brackets_are_nested_too
    assert_equal({ user: { name: "Ann" } }, parse("user%5Bname%5D=Ann"))
  end

  def test_a_name_outside_the_syntax_is_kept_whole
    assert_equal({ "a]": "1", "[b": "2" }, parse("a]=1&[b=2"))
  end

  def test_arrays_of_hashes_are_refused
    assert_raises(Monk::Params::Error) { parse("items[][name]=x") }
  end

  def test_a_key_used_as_a_value_and_a_hash_is_refused
    assert_raises(Monk::Params::Error) { parse("a=1&a[b]=2") }
    assert_raises(Monk::Params::Error) { parse("a[b]=2&a=1") }
    assert_raises(Monk::Params::Error) { parse("a[]=1&a[b]=2") }
    assert_raises(Monk::Params::Error) { parse("a[b]=2&a[]=1") }
  end

  def test_too_deep_is_refused
    ok = "a#{"[x]" * (Monk::Params::MAX_DEPTH - 1)}=1"
    parse(ok)

    assert_raises(Monk::Params::Error) { parse("a#{"[x]" * Monk::Params::MAX_DEPTH}=1") }
  end

  def test_too_many_pairs_is_refused
    parse(Array.new(Monk::Params::MAX_PAIRS) { |i| "k#{i}=1" }.join("&"))

    assert_raises(Monk::Params::Error) { parse(Array.new(Monk::Params::MAX_PAIRS + 1) { |i| "k#{i}=1" }.join("&")) }
  end

  def test_bad_percent_encoding_is_kept_as_written
    assert_equal({ a: "%zz" }, parse("a=%zz"))
  end

  def test_empty_names_are_skipped
    assert_equal({ a: "1" }, parse("&&=x&a=1"))
  end

  def test_parses_inside_a_worker_ractor
    result = Ractor.new { Monk::Params.parse("user[name]=Ann&tags[]=a") }.value

    assert_equal({ user: { name: "Ann" }, tags: ["a"] }, result)
  end
end
