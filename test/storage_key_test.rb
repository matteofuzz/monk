require_relative "test_helper"
require "monk/storage"

class StorageKeyTest < Minitest::Test
  KEY = Monk::Storage::Key

  def test_generate_puts_128_random_bits_under_the_prefix
    key = KEY.generate(prefix: "tmp")

    assert_match(%r{\Atmp/[0-9a-f]{32}\z}, key)
    refute_equal key, KEY.generate(prefix: "tmp")
  end

  def test_generate_accepts_a_nested_prefix
    assert_match(%r{\Aavatars/2026/[0-9a-f]{32}\z}, KEY.generate(prefix: "avatars/2026"))
  end

  def test_generate_validates_the_prefix
    ["", "../tmp", "Tmp", "tmp/"].each do |prefix|
      assert_raises(Monk::Storage::InvalidKeyError, prefix.inspect) { KEY.generate(prefix: prefix) }
    end
  end

  def test_valid_keys
    ["a", "tmp/1f0c", "media/2026-10/photo.jpg", "a_b/c-d/e.f", "0/1/2", "a..b"].each do |key|
      assert_equal key, KEY.validate!(key)
    end
  end

  def test_invalid_keys
    ["", "/a", "a/", "a//b", ".a", "a/.b", "..", "a/../b", "A", "a/B", "a b", "a\nb", "a\0b", "é", "a%2e",
     "a\\b", "a:b", nil, :a, 1,].each do |key|
      assert_raises(Monk::Storage::InvalidKeyError, key.inspect) { KEY.validate!(key) }
    end
  end

  def test_at_most_512_bytes
    assert KEY.validate!("a" * 512)
    assert_raises(Monk::Storage::InvalidKeyError) { KEY.validate!("a" * 513) }
  end

  def test_the_module_generates_keys_without_being_configured
    assert_match(%r{\Atmp/[0-9a-f]{32}\z}, Monk::Storage.generate_key(prefix: "tmp"))
  end
end
