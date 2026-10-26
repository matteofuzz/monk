require_relative "test_helper"
require "rack/mock"

# Monk::Storage is configured, and with STORAGE_URL unset tests use
# file://storage/test, apart from development's files: a file stored by
# key reads back, and its signed link answers. SETUP.md, storage.
class StorageTest < Minitest::Test
  def setup
    @key = Monk::Storage.generate_key(prefix: "check")
  end

  def teardown
    Monk::Storage.delete(@key)
  end

  def test_a_file_stored_by_key_reads_back
    Monk::Storage.put(@key, "hello", content_type: "text/plain")

    object = Monk::Storage.head(@key)
    assert_equal ["text/plain", 5], [object.content_type, object.byte_size]
    assert_equal "hello", Monk::Storage.get(@key)
  end

  def test_its_signed_link_answers
    Monk::Storage.put(@key, "hello", content_type: "text/plain")

    status, headers, body = APP.call(Rack::MockRequest.env_for(Monk::Storage.url(@key)))

    assert_equal 200, status
    assert_equal "text/plain", headers["content-type"]
    assert_equal "hello", body.to_enum(:each).to_a.join
  end
end
