require_relative "test_helper"
require_relative "support/storage_contract"
require "monk/storage"

class StorageFileBackendTest < Minitest::Test
  include StorageContract

  attr_reader :backend

  def setup
    @dir = Dir.mktmpdir("monk-storage")
    @root = File.join(@dir, "root")
    @backend = Monk::Storage::Backends::File.new(root: @root, secret: "s")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # docs/history/plan-storage.md decision 6.
  def test_bytes_and_metadata_live_side_by_side_under_root
    backend.put("media/a", "hello", content_type: "text/plain")

    assert_equal "hello", File.binread(File.join(@root, "objects", "media", "a~"))
    meta = JSON.parse(File.read(File.join(@root, "meta", "media", "a~.json")))
    assert_equal({ "content_type" => "text/plain", "byte_size" => 5, "etag" => Digest::MD5.hexdigest("hello") }, meta)
  end

  def test_writes_leave_no_temporary_files
    backend.put("media/a", "x")
    backend.put("media/a", "y")
    backend.copy("media/a", "media/b")

    leftovers = Dir.glob("**/*.tmp", base: @root)
    assert_empty leftovers
  end

  # An object without metadata is a put that died between the two renames:
  # not there yet, as in a bucket, where a PUT is all or nothing.
  def test_bytes_without_metadata_are_not_an_object
    FileUtils.mkdir_p(File.join(@root, "objects", "media"))
    File.binwrite(File.join(@root, "objects", "media", "half~"), "x")

    assert_nil backend.head("media/half")
    assert_raises(Monk::Storage::NotFoundError) { backend.get("media/half") }
  end

  def test_traversal_attempts_are_refused_before_touching_the_disk
    ["../outside", "media/../../outside", "%2e%2e/outside", "media/%2E%2E", "a\0b", "media/..", "./a",
     "media\\..\\x",].each do |key|
      assert_raises(Monk::Storage::InvalidKeyError, key.inspect) { backend.put(key, "x") }
    end

    refute File.exist?(File.join(@dir, "outside"))
    refute File.exist?(@root), "nothing was written"
  end

  # macOS disks are case-insensitive: "A" and "a" would be one file.
  def test_uppercase_keys_are_refused
    assert_raises(Monk::Storage::InvalidKeyError) { backend.put("media/Photo", "x") }
  end

  # A symbolic link under root can point anywhere on the disk.
  def test_a_symlink_inside_root_that_points_outside_is_refused
    outside = File.join(@dir, "outside")
    FileUtils.mkdir_p([outside, File.join(@root, "objects")])
    File.binwrite(File.join(outside, "secret~"), "private")
    File.symlink(outside, File.join(@root, "objects", "evil"))

    assert_raises(Monk::Storage::InvalidKeyError) { backend.put("evil/x", "x") }
    assert_raises(Monk::Storage::InvalidKeyError) { backend.get("evil/secret") }
    assert_raises(Monk::Storage::InvalidKeyError) { backend.copy("evil/secret", "media/stolen") }
    assert_equal ["secret~"], Dir.children(outside)
  end

  def test_a_symlinked_object_file_is_refused
    FileUtils.mkdir_p([File.join(@root, "objects", "media"), File.join(@root, "meta", "media")])
    File.write(File.join(@dir, "passwd"), "root:x")
    File.symlink(File.join(@dir, "passwd"), File.join(@root, "objects", "media", "link~"))
    File.write(File.join(@root, "meta", "media", "link~.json"), '{"content_type":"text/plain","byte_size":6}')

    assert_raises(Monk::Storage::InvalidKeyError) { backend.get("media/link") }
  end

  # The root itself may be a link (a volume mounted elsewhere, macOS's
  # /var -> /private/var): only links below it are refused.
  def test_root_may_be_a_symlink
    FileUtils.mkdir_p(@root)
    linked = File.join(@dir, "linked")
    File.symlink(@root, linked)
    backend = Monk::Storage::Backends::File.new(root: linked, secret: "s")

    backend.put("media/a", "via the link")

    assert_equal "via the link", backend.get("media/a")
  end

  def test_disk_errors_become_request_errors_with_the_cause
    FileUtils.mkdir_p(File.join(@root, "objects"))
    File.write(File.join(@root, "objects", "media"), "a file where a directory goes")

    error = assert_raises(Monk::Storage::RequestError) { backend.put("media/a", "x") }

    assert_kind_of SystemCallError, error.cause
  end

  # Worker Ractors call the backend straight from the frozen config.
  def test_every_operation_from_a_worker_ractor
    shared = Ractor.make_shareable(backend)

    result = Ractor.new(shared) do |storage|
      storage.put("tmp/r", "from a ractor", content_type: "text/plain")
      storage.copy("tmp/r", "media/r")
      storage.delete("tmp/r")
      [storage.get("media/r"), storage.get("media/r", range: 0..3), storage.head("media/r").byte_size,
       storage.head("tmp/r"),]
    end.value

    assert_equal ["from a ractor", "from", 13, nil], result
  end
end
