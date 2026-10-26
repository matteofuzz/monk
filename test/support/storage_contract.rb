require "digest/md5"
require "stringio"
require "tempfile"

# What every Monk::Storage backend does the same way
# (docs/history/plan-storage.md decision 2). A test class includes it and defines
# #backend, returning the backend under test, empty at the start of each
# test. The file backend runs it in storage_file_backend_test.rb; the S3
# backend runs it against floci (storage_s3_integration_test.rb).
module StorageContract
  BINARY = (0..255).map(&:chr).join.b.freeze

  def test_contract_put_returns_the_key_and_get_the_bytes
    assert_equal "media/a1", backend.put("media/a1", "hello")

    bytes = backend.get("media/a1")
    assert_equal "hello", bytes
    assert_predicate bytes, :frozen?
    assert_equal Encoding::BINARY, bytes.encoding
  end

  def test_contract_bytes_are_kept_exactly
    backend.put("media/bin", BINARY)

    assert_equal BINARY, backend.get("media/bin")
  end

  def test_contract_empty_object
    backend.put("media/empty", "")

    assert_equal "", backend.get("media/empty")
    assert_equal 0, backend.head("media/empty").byte_size
  end

  def test_contract_head_of_a_missing_key_is_nil
    assert_nil backend.head("media/nothing")
  end

  def test_contract_head_describes_the_object
    backend.put("media/pic", "png bytes", content_type: "image/png")

    assert_equal Monk::Storage::Object.new(key: "media/pic", byte_size: 9, content_type: "image/png",
      etag: Digest::MD5.hexdigest("png bytes"),), backend.head("media/pic")
  end

  def test_contract_content_type_defaults_to_octet_stream
    backend.put("media/blob", "x")

    assert_equal "application/octet-stream", backend.head("media/blob").content_type
  end

  def test_contract_put_overwrites
    backend.put("media/a", "first", content_type: "text/plain")
    backend.put("media/a", "second!", content_type: "image/png")

    assert_equal "second!", backend.get("media/a")
    assert_equal 7, backend.head("media/a").byte_size
    assert_equal "image/png", backend.head("media/a").content_type
  end

  def test_contract_get_of_a_missing_key_raises_not_found
    assert_raises(Monk::Storage::NotFoundError) { backend.get("media/nothing") }
  end

  def test_contract_delete_removes_and_is_idempotent
    backend.put("media/gone", "x")

    assert_nil backend.delete("media/gone")
    assert_nil backend.delete("media/gone")
    assert_nil backend.delete("media/never-there")
    assert_nil backend.head("media/gone")
    assert_raises(Monk::Storage::NotFoundError) { backend.get("media/gone") }
  end

  # The confirm step: out of tmp/, then the tmp/ object deleted.
  def test_contract_copy_then_delete_the_source
    backend.put("tmp/up", "photo", content_type: "image/jpeg")

    assert_equal "media/photo", backend.copy("tmp/up", "media/photo")
    backend.delete("tmp/up")

    assert_equal "photo", backend.get("media/photo")
    assert_equal "image/jpeg", backend.head("media/photo").content_type
    assert_nil backend.head("tmp/up")
  end

  def test_contract_copy_overwrites_the_target
    backend.put("media/a", "new")
    backend.put("media/b", "old and longer")

    backend.copy("media/a", "media/b")

    assert_equal "new", backend.get("media/b")
    assert_equal 3, backend.head("media/b").byte_size
  end

  def test_contract_copy_of_a_missing_key_raises_not_found
    assert_raises(Monk::Storage::NotFoundError) { backend.copy("tmp/nothing", "media/x") }
    assert_nil backend.head("media/x")
  end

  # A bucket keeps both; on disk one is a file and the other needs a
  # directory of the same name.
  def test_contract_a_key_and_a_longer_key_under_it_coexist
    backend.put("media/a", "short")
    backend.put("media/a/b", "long")

    assert_equal "short", backend.get("media/a")
    assert_equal "long", backend.get("media/a/b")
  end

  def test_contract_io_bodies
    backend.put("media/sio", StringIO.new("from a StringIO"))
    Tempfile.create("monk-storage") do |file|
      file.binmode
      file.write(BINARY * 1000)
      file.flush
      backend.put("media/temp", file)
    end

    assert_equal "from a StringIO", backend.get("media/sio")
    assert_equal BINARY * 1000, backend.get("media/temp")
  end

  # An IO already read to the end is stored whole: it's rewound first.
  def test_contract_io_body_is_rewound
    io = StringIO.new("whole")
    io.read

    backend.put("media/rewound", io)

    assert_equal "whole", backend.get("media/rewound")
  end

  def test_contract_ranged_get
    backend.put("media/r", "0123456789")

    assert_equal "0123", backend.get("media/r", range: 0..3)
    assert_equal "01", backend.get("media/r", range: 0...2)
    assert_equal "789", backend.get("media/r", range: 7..)
    assert_equal "89", backend.get("media/r", range: 8..100)
    assert_equal "", backend.get("media/r", range: 10..15)
    assert_equal "", backend.get("media/r", range: 50..60)
    assert_predicate backend.get("media/r", range: 0..3), :frozen?
  end

  def test_contract_ranged_get_of_a_missing_key_raises_not_found
    assert_raises(Monk::Storage::NotFoundError) { backend.get("media/nothing", range: 0..15) }
  end

  def test_contract_invalid_ranges_raise
    backend.put("media/r", "0123456789")

    [5..2, -3.., ..4, "0..3", 0.5..2, 3...3].each do |range|
      assert_raises(ArgumentError, range.inspect) { backend.get("media/r", range: range) }
    end
  end

  def test_contract_every_operation_validates_the_key
    ["../x", "Media/a", "", "/a", "a//b", "a/", ".hidden", "a/../b", "a\0b", 42].each do |key|
      assert_raises(Monk::Storage::InvalidKeyError, key.inspect) { backend.put(key, "x") }
      assert_raises(Monk::Storage::InvalidKeyError, key.inspect) { backend.get(key) }
      assert_raises(Monk::Storage::InvalidKeyError, key.inspect) { backend.head(key) }
      assert_raises(Monk::Storage::InvalidKeyError, key.inspect) { backend.delete(key) }
    end
    backend.put("media/ok", "x")
    assert_raises(Monk::Storage::InvalidKeyError) { backend.copy("media/ok", "../x") }
    assert_raises(Monk::Storage::InvalidKeyError) { backend.copy("../x", "media/ok") }
  end

  def test_contract_invalid_content_types_raise
    ["", "png", "image/png\r\nX-Evil: 1", nil, :png].each do |type|
      assert_raises(ArgumentError, type.inspect) { backend.put("media/a", "x", content_type: type) }
    end
    assert_nil backend.head("media/a")
  end

  def test_contract_content_type_with_parameters
    backend.put("media/t", "hi", content_type: "text/plain; charset=utf-8")

    assert_equal "text/plain; charset=utf-8", backend.head("media/t").content_type
  end

  def test_contract_invalid_bodies_raise
    [nil, 42, Object.new, %w[a b]].each do |body|
      assert_raises(ArgumentError, body.inspect) { backend.put("media/a", body) }
    end
    assert_nil backend.head("media/a")
  end
end
