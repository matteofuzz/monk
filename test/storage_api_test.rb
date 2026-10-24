require_relative "test_helper"
require "monk/storage"

# Monk::Storage's own methods: the configured backend's, each logged.
class StorageApiTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("monk-storage")
  end

  def teardown
    Monk::Storage.reset!
    FileUtils.remove_entry(@dir)
  end

  # Runs the block with Monk::Storage on a file backend in a tmpdir and
  # Monk::Log writing to another; returns the log file's contents.
  def logged
    with_log do |log_dir|
      Monk::Storage.configure(url: "file://#{@dir}/root")
      Monk::Settings.freeze_registry!
      Monk::Log.freeze_registry!
      yield
      path = File.join(log_dir, "test.log")
      File.exist?(path) ? File.read(path) : ""
    end
  end

  def test_calls_go_to_the_configured_backend
    logged do
      assert_equal "tmp/a", Monk::Storage.put("tmp/a", "hello", content_type: "text/plain")
      assert_equal "media/a", Monk::Storage.copy("tmp/a", "media/a")
      assert_nil Monk::Storage.delete("tmp/a")

      assert_equal "hello", Monk::Storage.get("media/a")
      assert_equal "he", Monk::Storage.get("media/a", range: 0..1)
      assert_equal "text/plain", Monk::Storage.head("media/a").content_type
      assert_nil Monk::Storage.head("tmp/a")
    end

    assert_equal "hello", File.binread(File.join(@dir, "root", "objects", "media", "a~"))
  end

  def test_each_call_writes_one_log_line
    log = logged do
      Monk::Storage.put("tmp/a", "hello")
      Monk::Storage.get("tmp/a", range: 0..1)
      Monk::Storage.head("tmp/a")
      Monk::Storage.head("tmp/none")
      Monk::Storage.copy("tmp/a", "media/a")
      Monk::Storage.delete("tmp/a")
    end

    lines = log.lines.grep(/\[storage\]/)
    assert_equal 6, lines.size
    assert_match(%r{\[storage\] put key=tmp/a bytes=5 \d+ms$}, lines[0])
    assert_match(%r{\[storage\] get key=tmp/a bytes=2 \d+ms$}, lines[1])
    assert_match(%r{\[storage\] head key=tmp/a bytes=5 \d+ms$}, lines[2])
    assert_match(%r{\[storage\] head key=tmp/none missing \d+ms$}, lines[3])
    assert_match(%r{\[storage\] copy key=tmp/a to=media/a \d+ms$}, lines[4])
    assert_match(%r{\[storage\] delete key=tmp/a \d+ms$}, lines[5])
  end

  # A refused call logs nothing, so a key that failed validation never
  # reaches the log.
  def test_a_failed_call_is_not_logged
    log = logged do
      assert_raises(Monk::Storage::InvalidKeyError) { Monk::Storage.put("a\nfake line", "x") }
      assert_raises(Monk::Storage::NotFoundError) { Monk::Storage.get("tmp/none") }
    end

    assert_empty log.lines.grep(/\[storage\]/)
  end

  def test_calls_before_configure_raise
    %i[head get delete].each do |name|
      assert_raises(Monk::Storage::NotConfiguredError, name.to_s) { Monk::Storage.public_send(name, "tmp/a") }
    end
    assert_raises(Monk::Storage::NotConfiguredError) { Monk::Storage.put("tmp/a", "x") }
    assert_raises(Monk::Storage::NotConfiguredError) { Monk::Storage.copy("tmp/a", "tmp/b") }
  end

  # The way a route uses it: Monk::Storage from a worker Ractor, after boot.
  def test_the_api_from_a_worker_ractor_after_freeze
    with_log do
      Monk::Storage.configure(url: "file://#{@dir}/root")
      Monk::Settings.freeze_registry!
      Monk.freeze!

      result = Ractor.new do
        key = Monk::Storage.generate_key(prefix: "tmp")
        Monk::Storage.put(key, "from a worker", content_type: "text/plain")
        [Monk::Storage.get(key), Monk::Storage.head(key).content_type]
      end.value

      assert_equal ["from a worker", "text/plain"], result
    end
  end
end
