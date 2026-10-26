require_relative "test_helper"
require_relative "support/fake_s3_server"
require "monk/storage"
require "time"

# What the S3 backend sends, checked against a fake server and the Phase 4
# signer. storage_s3_integration_test.rb runs it against a real one.
class StorageS3BackendTest < Minitest::Test
  SIG = Monk::Storage::SigV4

  def teardown
    @server&.stop
  end

  def serve(*responses, silent: false)
    @server = FakeS3Server.new(responses: responses, silent: silent)
  end

  def backend(**overrides)
    Monk::Storage::Backends::S3.new(bucket: "media", endpoint: @server&.endpoint || "s3.example.test",
      region: "eu-central", access_key: "AKID", secret_key: "hunter2", path_style: true, tls: false, **overrides,)
  end

  # Re-signs the recorded request from its own headers: the signature only
  # matches if every signed header, the path and the payload hash are what
  # the backend signed.
  def assert_signed(request)
    names = request.headers["authorization"][/SignedHeaders=([^,]+)/, 1].split(";")
    path, query = request.target.split("?", 2)
    params = URI.decode_www_form(query.to_s).to_h
    now = Time.strptime(request.headers["x-amz-date"], "%Y%m%dT%H%M%S%z").to_i
    expected = SIG.sign_headers(method: request.verb, path: URI.decode_uri_component(path), query: params,
      headers: request.headers.slice(*names - ["x-amz-date"]), payload_hash: request.headers["x-amz-content-sha256"],
      credentials: { access_key: "AKID", secret_key: "hunter2", region: "eu-central" }, now: now,)

    assert_equal expected["authorization"], request.headers["authorization"]
    assert_includes names, "host"
    assert_includes names, "x-amz-content-sha256"
  end

  def test_put_sends_the_body_signed_with_its_hash
    serve
    assert_equal "tmp/a", backend.put("tmp/a", "hello", content_type: "text/plain")

    request = @server.next_request
    assert_equal ["PUT", "/media/tmp/a", "hello"], [request.verb, request.target, request.body]
    assert_equal "text/plain", request.headers["content-type"]
    assert_equal "5", request.headers["content-length"]
    assert_equal Digest::SHA256.hexdigest("hello"), request.headers["x-amz-content-sha256"]
    assert_equal @server.endpoint, request.headers["host"]
    assert_signed(request)
  end

  # An IO is hashed, rewound and streamed whole, even one already read.
  def test_put_streams_an_io_body
    serve
    io = StringIO.new("streamed body")
    io.read

    backend.put("tmp/io", io)

    request = @server.next_request
    assert_equal "streamed body", request.body
    assert_equal Digest::SHA256.hexdigest("streamed body"), request.headers["x-amz-content-sha256"]
    assert_signed(request)
  end

  def test_get_with_a_range
    serve([206, {}, "0123"], [206, {}, "789"], [200, {}, "all"])

    assert_equal "0123", backend.get("media/a", range: 0..3)
    assert_equal "789", backend.get("media/a", range: 7..)
    bytes = backend.get("media/a")

    assert_equal "bytes=0-3", @server.next_request.headers["range"]
    assert_equal "bytes=7-", @server.next_request.headers["range"]
    request = @server.next_request
    assert_nil request.headers["range"]
    assert_equal SIG::EMPTY_PAYLOAD, request.headers["x-amz-content-sha256"]
    assert_signed(request)
    assert_predicate bytes, :frozen?
    assert_equal Encoding::BINARY, bytes.encoding
  end

  # docs/history/plan-storage.md decision 12: a range past the end is "".
  def test_get_maps_a_416_to_empty
    serve([416, {}, "<Error><Code>InvalidRange</Code></Error>"])

    assert_equal "", backend.get("media/a", range: 50..60)
  end

  def test_get_of_a_missing_key_raises_not_found
    serve([404, {}, "<Error><Code>NoSuchKey</Code></Error>"])

    assert_raises(Monk::Storage::NotFoundError) { backend.get("media/none") }
  end

  def test_head_describes_the_object
    serve([200, { "content-length" => "1234", "content-type" => "image/png", "etag" => '"abc123"' }, ""])

    assert_equal Monk::Storage::Object.new(key: "media/a", byte_size: 1234, content_type: "image/png",
      etag: "abc123",), backend.head("media/a")
    assert_equal "HEAD", @server.next_request.verb
  end

  def test_head_of_a_missing_key_is_nil
    serve([404, {}, ""])

    assert_nil backend.head("media/none")
  end

  # A bucket that doesn't grant ListBucket answers 403 for a missing key:
  # not nil, the credentials need fixing.
  def test_head_forbidden_is_a_request_error
    serve([403, {}, ""])

    error = assert_raises(Monk::Storage::RequestError) { backend.head("media/a") }
    assert_includes error.message, "403"
  end

  def test_delete
    serve([204, {}, ""])

    assert_nil backend.delete("media/a")
    request = @server.next_request
    assert_equal ["DELETE", "/media/media/a"], [request.verb, request.target]
    assert_signed(request)
  end

  def test_copy_names_the_source
    serve([200, {}, "<CopyObjectResult><ETag>x</ETag></CopyObjectResult>"])

    assert_equal "media/b", backend.copy("tmp/a", "media/b")
    request = @server.next_request
    assert_equal ["PUT", "/media/media/b", ""], [request.verb, request.target, request.body]
    assert_equal "/media/tmp/a", request.headers["x-amz-copy-source"]
    assert_signed(request)
  end

  # S3 can answer 200 to a copy that failed.
  def test_copy_with_an_error_in_a_200_raises
    serve([200, {}, "<Error><Code>InternalError</Code><Message>try again</Message></Error>"])

    error = assert_raises(Monk::Storage::RequestError) { backend.copy("tmp/a", "media/b") }
    assert_includes error.message, "InternalError: try again"
  end

  def test_copy_of_a_missing_source_raises_not_found
    serve([404, {}, "<Error><Code>NoSuchKey</Code></Error>"])

    assert_raises(Monk::Storage::NotFoundError) { backend.copy("tmp/none", "media/b") }
  end

  def test_errors_name_the_s3_code_and_never_the_secret
    serve([500, {}, "<Error><Code>SlowDown</Code><Message>Reduce your request rate</Message></Error>"])

    error = assert_raises(Monk::Storage::RequestError) { backend.put("tmp/a", "x") }
    assert_includes error.message, "HTTP 500 SlowDown: Reduce your request rate"
    refute_includes error.message, "hunter2"
  end

  def test_an_unreachable_server_is_a_request_error_with_the_cause
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close

    error = assert_raises(Monk::Storage::RequestError) { backend(endpoint: "127.0.0.1:#{port}").get("media/a") }
    assert_kind_of SystemCallError, error.cause
  end

  def test_a_server_that_never_answers_times_out
    serve(silent: true)

    error = assert_raises(Monk::Storage::RequestError) { backend(read_timeout: 0.2).get("media/a") }
    assert_kind_of Net::ReadTimeout, error.cause
  end

  def test_every_operation_validates_the_key_before_sending
    serve
    %i[get head delete].each do |name|
      assert_raises(Monk::Storage::InvalidKeyError) { backend.public_send(name, "../x") }
    end
    assert_raises(Monk::Storage::InvalidKeyError) { backend.put("../x", "x") }
    assert_raises(Monk::Storage::InvalidKeyError) { backend.copy("media/a", "../x") }
    assert_raises(Monk::Storage::InvalidKeyError) { backend.url("../x", expires_in: 60, cache_window: 60) }

    assert_nil @server.requests.pop(timeout: 0.1), "nothing was sent"
  end

  def test_virtual_hosted_links_put_the_bucket_in_the_host
    link = backend(endpoint: "fsn1.your-objectstorage.com", path_style: false, tls: true)
           .url("media/a", expires_in: 3600, cache_window: 3600, now: 1_800_000_000)

    assert link.start_with?("https://media.fsn1.your-objectstorage.com/media/a?X-Amz-Algorithm=AWS4-HMAC-SHA256&")
  end

  def test_path_style_links_put_the_bucket_in_the_path
    link = backend(endpoint: "127.0.0.1:4566").url("media/a", expires_in: 3600, cache_window: 3600, now: 0)

    assert link.start_with?("http://127.0.0.1:4566/media/media/a?")
  end

  # docs/history/plan-storage.md decision 9: signed at the window's start, valid
  # for the window plus expires_in, the same URL all window long.
  def test_url_is_the_same_within_one_cache_window
    window_start = 1_800_000_000 - (1_800_000_000 % 3600)
    at = ->(now) { backend.url("media/a", expires_in: 3600, cache_window: 3600, now: now) }

    assert_equal at.call(window_start), at.call(window_start + 3599)
    refute_equal at.call(window_start + 3599), at.call(window_start + 3600)
    link = at.call(window_start + 100)
    assert_includes link, "X-Amz-Date=#{Time.at(window_start).utc.strftime("%Y%m%dT%H%M%SZ")}&"
    assert_includes link, "X-Amz-Expires=7200&"
    assert_includes link, "X-Amz-SignedHeaders=host&"
  end

  def test_presigned_put_signs_length_and_type
    upload = backend.presigned_put("tmp/a", content_type: "image/png", byte_size: 42, expires_in: 600, now: 0)

    assert_includes upload.url, "X-Amz-Expires=600&"
    assert_includes upload.url, "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost&"
    assert_equal({ "Content-Type" => "image/png", "Content-Length" => "42" }, upload.headers)
  end

  def test_backend_never_shows_its_secret
    refute_includes backend.inspect, "hunter2"
  end
end
