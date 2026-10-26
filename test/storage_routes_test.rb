require_relative "test_helper"
require "monk/storage"

# The file backend's /_monk/storage routes, through a booted app: the
# browser's side of an upload and a download (docs/history/plan-storage.md
# Phase 3).
class StorageRoutesTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)
  PNG = "\x89PNG\r\n\x1A\n-image-bytes".b.freeze

  def setup
    @dir = Dir.mktmpdir("monk-storage")
    Monk::Storage.configure(url: "file://#{@dir}/root")
    @app = Class.new(Monk::Base) { get("/") { "home" } }
    capture_io { Monk.boot(@app) }
  end

  def teardown
    Monk::Storage.reset!
    FileUtils.remove_entry(@dir)
  end

  def request(method, url, body: "", headers: {})
    env = env_for(method, url).merge("rack.input" => StringIO.new(body.b))
    headers.each do |name, value|
      key = name.downcase.tr("-", "_")
      env[%w[content_type content_length].include?(key) ? key.upcase : "HTTP_#{key.upcase}"] = value
    end
    status, response_headers, response_body = @app.call(env)
    [status, response_headers, response_body.join]
  end

  def put_upload(upload, body)
    request("PUT", upload.url, body: body, headers: upload.headers)
  end

  def backend
    Monk::Storage.config[:backend]
  end

  # The flow an app's routes and the browser go through together.
  def test_upload_confirm_and_download
    upload = Monk::Storage.presigned_put("tmp/up1", content_type: "image/png", byte_size: PNG.bytesize)
    assert_match(%r{\A/_monk/storage/[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z}, upload.url)
    assert_equal({ "Content-Type" => "image/png", "Content-Length" => PNG.bytesize.to_s }, upload.headers)

    status, headers, = put_upload(upload, PNG)
    assert_equal 200, status
    assert_equal %("#{Digest::MD5.hexdigest(PNG)}"), headers["etag"]

    assert_equal PNG.bytesize, Monk::Storage.head("tmp/up1").byte_size
    Monk::Storage.copy("tmp/up1", "media/up1")
    Monk::Storage.delete("tmp/up1")

    status, headers, body = request("GET", Monk::Storage.url("media/up1"))
    assert_equal 200, status
    assert_equal PNG, body
    assert_equal "image/png", headers["content-type"]
    assert_equal PNG.bytesize.to_s, headers["content-length"]
    assert_equal "bytes", headers["accept-ranges"]
    assert_equal "nosniff", headers["x-content-type-options"]
    max_age = headers["cache-control"][/\Aprivate, max-age=(\d+)\z/, 1].to_i
    assert_operator max_age, :>=, 3600, "valid at least expires_in"
    assert_operator max_age, :<=, 7200, "at most the window plus expires_in"
  end

  def test_a_tampered_or_foreign_token_is_forbidden
    url = Monk::Storage.url("media/a")
    foreign = Monk::Storage::Backends::File.new(root: "#{@dir}/root", secret: "another")
                                           .url("media/a", expires_in: 60, cache_window: 60)

    [url.sub(/.\z/) { |c| c == "A" ? "B" : "A" }, foreign, "/_monk/storage/", "/_monk/storage/x.y",
     "/_monk/storage/#{"a" * 50}",].each do |bad|
      assert_equal 403, request("GET", bad).first, bad
    end
  end

  def test_an_expired_link_is_forbidden
    Monk::Storage.put("media/a", "x")
    past = Time.now.to_i - 10_000
    expired_get = backend.url("media/a", expires_in: 60, cache_window: 60, now: past)
    expired_put = backend.presigned_put("tmp/b", content_type: "text/plain", byte_size: 1, expires_in: 60, now: past)

    assert_equal 403, request("GET", expired_get).first
    assert_equal 403, put_upload(expired_put, "x").first
    assert_nil Monk::Storage.head("tmp/b")
  end

  # The method is inside the signature, as in SigV4.
  def test_a_link_works_only_with_its_own_method
    Monk::Storage.put("media/a", "x")
    upload = Monk::Storage.presigned_put("tmp/b", content_type: "text/plain", byte_size: 1)
    download = Monk::Storage.url("media/a")

    assert_equal 403, request("GET", upload.url).first
    assert_equal 403, request("PUT", download, body: "y", headers: { "Content-Type" => "text/plain",
                                                                     "Content-Length" => "1", },).first
    assert_equal 403, request("HEAD", download).first
    assert_equal 403, request("DELETE", download).first
    assert_equal "x", Monk::Storage.get("media/a")
  end

  def test_a_put_with_another_length_or_type_than_signed_is_forbidden
    upload = Monk::Storage.presigned_put("tmp/b", content_type: "image/png", byte_size: 5)

    assert_equal 403, request("PUT", upload.url, body: "123456",
      headers: upload.headers.merge("Content-Length" => "6"),).first
    assert_equal 403, request("PUT", upload.url, body: "12345",
      headers: upload.headers.merge("Content-Type" => "text/html"),).first
    assert_equal 403, request("PUT", upload.url, body: "12345", headers: { "Content-Type" => "image/png" }).first
    assert_nil Monk::Storage.head("tmp/b")
  end

  # Content-Length says one thing and the body another: a 400, as S3
  # answers IncompleteBody, and nothing is stored.
  def test_a_body_that_isnt_its_declared_length_is_a_bad_request
    upload = Monk::Storage.presigned_put("tmp/b", content_type: "image/png", byte_size: 5)

    status, headers, = put_upload(upload, "1234")
    assert_equal 400, status
    assert_equal "nosniff", headers["x-content-type-options"]
    assert_equal 400, put_upload(upload, "123456").first
    assert_nil Monk::Storage.head("tmp/b")
    assert_empty Dir.glob("**/*.tmp", base: "#{@dir}/root")
  end

  # Re-sending the same upload (a retried request) replaces it.
  def test_an_upload_link_can_be_used_again_until_it_expires
    upload = Monk::Storage.presigned_put("tmp/b", content_type: "text/plain", byte_size: 3)

    assert_equal 200, put_upload(upload, "one").first
    assert_equal 200, put_upload(upload, "two").first
    assert_equal "two", Monk::Storage.get("tmp/b")
  end

  def test_a_missing_object_is_not_found
    url = Monk::Storage.url("media/gone")

    status, headers, = request("GET", url)
    assert_equal 404, status
    assert_equal "nosniff", headers["x-content-type-options"]
  end

  def test_range_requests_get_partial_content
    Monk::Storage.put("media/v", "0123456789", content_type: "video/mp4")
    url = Monk::Storage.url("media/v")

    {
      "bytes=0-3" => ["0123", "bytes 0-3/10"],
      "bytes=7-" => ["789", "bytes 7-9/10"],
      "bytes=-2" => ["89", "bytes 8-9/10"],
      "bytes=8-100" => ["89", "bytes 8-9/10"],
      "bytes=-50" => ["0123456789", "bytes 0-9/10"],
      "bytes=0-0" => ["0", "bytes 0-0/10"],
    }.each do |range, (bytes, content_range)|
      status, headers, body = request("GET", url, headers: { "Range" => range })
      assert_equal 206, status, range
      assert_equal bytes, body, range
      assert_equal content_range, headers["content-range"], range
      assert_equal bytes.bytesize.to_s, headers["content-length"], range
      assert_equal "video/mp4", headers["content-type"], range
    end
  end

  def test_an_unsatisfiable_range_is_refused
    Monk::Storage.put("media/v", "0123456789")
    url = Monk::Storage.url("media/v")

    %w[bytes=10- bytes=50-60 bytes=-0].each do |range|
      status, headers, = request("GET", url, headers: { "Range" => range })
      assert_equal 416, status, range
      assert_equal "bytes */10", headers["content-range"], range
    end
  end

  # A Range this doesn't read is ignored, and the whole object sent.
  def test_other_range_headers_get_the_whole_object
    Monk::Storage.put("media/v", "0123456789")
    url = Monk::Storage.url("media/v")

    ["bytes=0-1,4-5", "items=0-3", "bytes=5-2", "bytes=-", "bytes=a-b"].each do |range|
      status, _, body = request("GET", url, headers: { "Range" => range })
      assert_equal [200, "0123456789"], [status, body], range
    end
  end

  # docs/history/plan-storage.md decision 9.
  def test_the_same_url_within_one_cache_window
    window_start = 1_800_000_000 - (1_800_000_000 % 3600)
    at = ->(now) { backend.url("media/a", expires_in: 3600, cache_window: 3600, now: now) }

    assert_equal at.call(window_start), at.call(window_start + 3599)
    refute_equal at.call(window_start + 3599), at.call(window_start + 3600)
  end

  def test_url_validates_its_times
    [{ expires_in: 0 }, { cache_window: -1 }, { expires_in: 1.5 }, { expires_in: 7 * 86_400, cache_window: 1 }]
      .each do |times|
        assert_raises(ArgumentError, times.inspect) { Monk::Storage.url("media/a", **times) }
      end
  end

  def test_configure_validates_the_default_times
    assert_raises(ArgumentError) { Monk::Storage.configure(url: "file://x", cache_window: 6 * 86_400, expires_in: 86_401) }
    assert_raises(ArgumentError) { Monk::Storage.configure(url: "file://x", expires_in: "3600") }
  end

  def test_configured_defaults_are_used
    Monk::Storage.reset!
    Monk::Storage.configure(url: "file://#{@dir}/root", expires_in: 60, cache_window: 60)
    Monk::Storage.put("media/a", "x")

    _, headers, = request("GET", Monk::Storage.url("media/a"))

    assert_operator headers["cache-control"][/max-age=(\d+)/, 1].to_i, :<=, 120
  end

  def test_presigned_put_validates_its_arguments
    assert_raises(ArgumentError) { Monk::Storage.presigned_put("tmp/a", content_type: "png", byte_size: 1) }
    assert_raises(ArgumentError) { Monk::Storage.presigned_put("tmp/a", content_type: "image/png", byte_size: -1) }
    assert_raises(ArgumentError) { Monk::Storage.presigned_put("tmp/a", content_type: "image/png", byte_size: "1") }
    assert_raises(Monk::Storage::InvalidKeyError) do
      Monk::Storage.presigned_put("../a", content_type: "image/png", byte_size: 1)
    end
  end

  def test_other_paths_still_reach_the_app
    assert_equal [200, "home"], request("GET", "/").values_at(0, 2)
    assert_equal 404, request("GET", "/_monk/storagex").first
  end

  # bin/jobs builds a link and the web process serves it: in development
  # and test both sign with the same fixed secret.
  def test_a_link_built_by_another_process_is_accepted
    script = %(require "monk/storage"; Monk::Storage.configure(url: "file://#{@dir}/root"); ) \
             "print Monk::Storage.url(\"media/a\")"
    out, err, status = Open3.capture3({ "MONK_ENV" => "test" }, RbConfig.ruby, "-I", LIB, "-e", script)
    assert status.success?, err
    Monk::Storage.put("media/a", "from the other process's link")

    assert_equal [200, "from the other process's link"], request("GET", out).values_at(0, 2)
  end

  # No routes with an S3 backend: its links point at the bucket.
  def test_no_route_with_an_s3_backend
    Monk::Storage.reset!
    Monk::Storage.configure(url: "s3://k:s@media?endpoint=s3.example.test&region=eu")
    token = Monk::Storage::Token.sign({ m: "GET", k: "media/a", e: Time.now.to_i + 60 }, "s")

    assert_equal 404, request("GET", "/_monk/storage/#{token}").first
  end

  def test_no_route_before_configure
    Monk::Storage.reset!

    assert_equal 404, request("GET", "/_monk/storage/x.y").first
  end

  # An app that never requires monk/storage: Base has no hard dependency.
  def test_no_route_without_monk_storage
    script = <<~RUBY
      require "monk"
      app = Class.new(Monk::Base) { get("/") { "home" } }
      $stdout = StringIO.new
      Monk.boot(app)
      status, = app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/_monk/storage/x.y", "rack.input" => StringIO.new)
      STDOUT.print defined?(Monk::Storage).inspect, " ", status
    RUBY
    out, err, status = Open3.capture3({ "MONK_ENV" => "test" }, RbConfig.ruby, "-I", LIB, "-rstringio", "-e", script)

    assert status.success?, err
    assert_equal "nil 404", out
  end

  # Worker Ractors serve these requests, reading the frozen config.
  def test_routes_from_a_worker_ractor
    Monk::Storage.put("media/r", "served from a worker", content_type: "text/plain")
    url = Monk::Storage.url("media/r")
    upload = Monk::Storage.presigned_put("tmp/r", content_type: "text/plain", byte_size: 2)
    Monk.freeze!

    result = Ractor.new(url, upload.url) do |download, put|
      get = Monk::Storage.response("REQUEST_METHOD" => "GET", "PATH_INFO" => download)
      sent = Monk::Storage.response("REQUEST_METHOD" => "PUT", "PATH_INFO" => put, "CONTENT_LENGTH" => "2",
        "CONTENT_TYPE" => "text/plain", "rack.input" => StringIO.new("ok"),)
      [get[0], get[2].join, sent[0]]
    end.value

    assert_equal [200, "served from a worker", 200], result
    assert_equal "ok", Monk::Storage.get("tmp/r")
  end
end
