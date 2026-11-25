require_relative "test_helper"
require_relative "support/storage_contract"
require "monk/storage"

# The S3 backend against a real S3 server, a local floci that checks
# signatures (docs/history/plan-storage.md Phase 5): the contract every backend
# meets, then the browser's side of an upload and a download, the ADR's
# spike rebuilt as a test. Never skipped: StorageTestHelpers fails, naming
# the docker command, when the server isn't there.
class StorageS3IntegrationTest < Minitest::Test
  include StorageTestHelpers
  include StorageContract

  attr_reader :backend

  def setup
    @backend = s3_test_backend
  end

  # Net::HTTP standing in for the browser: sends exactly what it's given.
  def browser(method, url, body: nil, headers: {})
    uri = URI(url)
    request = Net::HTTPGenericRequest.new(method, !body.nil?, method != "HEAD", uri.request_uri, headers)
    request.body = body if body
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 10) do |http|
      http.request(request)
    end
  end

  def upload(key, body, content_type: "image/png", byte_size: body.bytesize)
    backend.presigned_put(key, content_type: content_type, byte_size: byte_size, expires_in: 600)
  end

  def test_browser_upload_confirm_and_download
    image = "\x89PNG\r\n\x1A\nimage".b
    link = upload("tmp/up", image)

    assert_equal "200", browser("PUT", link.url, body: image, headers: link.headers).code
    assert_equal image.bytesize, backend.head("tmp/up").byte_size
    assert_equal "\x89PNG".b, backend.get("tmp/up", range: 0..3)
    backend.copy("tmp/up", "media/up")
    backend.delete("tmp/up")

    response = browser("GET", backend.url("media/up", expires_in: 3600, cache_window: 3600))
    assert_equal "200", response.code
    assert_equal image, response.body.b
    assert_equal "image/png", response["content-type"]
    assert_nil backend.head("tmp/up")
  end

  # Content-Length and Content-Type are inside the presigned PUT's
  # signature: the bucket refuses any other, and stores nothing.
  def test_the_bucket_refuses_a_put_of_another_length_or_type
    link = upload("tmp/up", "12345")

    longer = browser("PUT", link.url, body: "123456", headers: link.headers.merge("Content-Length" => "6"))
    other_type = browser("PUT", link.url, body: "12345", headers: link.headers.merge("Content-Type" => "text/html"))

    assert_equal "403", longer.code
    assert_equal "403", other_type.code
    assert_nil backend.head("tmp/up")
  end

  def test_a_tampered_link_is_refused
    backend.put("media/a", "x")
    link = backend.url("media/a", expires_in: 60, cache_window: 60)

    assert_equal "403", browser("GET", link.sub(/.\z/) { |c| c == "a" ? "b" : "a" }).code
  end

  # docs/plan-storage-cache.md: the bucket answers with the Cache-Control
  # the link asks for, and a link asking for another one is refused.
  def test_a_signed_link_is_cached_for_expires_in
    backend.put("media/a", "x")
    link = backend.url("media/a", expires_in: 60, cache_window: 60)

    assert_equal "private, max-age=60", browser("GET", link)["cache-control"]
    assert_equal "403", browser("GET", link.sub("max-age%3D60", "max-age%3D99")).code
  end

  def test_an_expired_link_is_refused
    backend.put("media/a", "x")
    link = backend.url("media/a", expires_in: 60, cache_window: 60, now: Time.now.to_i - 3600)

    assert_equal "403", browser("GET", link).code
  end

  # The browser's <video> asks for ranges: the bucket answers 206.
  def test_a_signed_link_answers_ranges
    backend.put("media/v", "0123456789", content_type: "video/mp4")
    response = browser("GET", backend.url("media/v", expires_in: 60, cache_window: 60),
      headers: { "Range" => "bytes=2-4" },)

    assert_equal ["206", "234", "bytes 2-4/10"], [response.code, response.body, response["content-range"]]
  end

  # How a route uses it: Monk::Storage from a worker Ractor, after boot.
  def test_the_flow_from_a_worker_ractor
    Monk::Storage.configure(url: storage_test_url)
    Monk.freeze!

    result = Ractor.new do
      key = Monk::Storage.generate_key(prefix: "tmp")
      Monk::Storage.put(key, "from a worker", content_type: "text/plain")
      final = key.sub("tmp/", "media/")
      Monk::Storage.copy(key, final)
      Monk::Storage.delete(key)
      [Monk::Storage.get(final), Monk::Storage.get(final, range: 0..3), Monk::Storage.head(final).content_type,
       Monk::Storage.head(key), URI(Monk::Storage.url(final)).scheme,
       Monk::Storage.presigned_put("tmp/next", content_type: "text/plain", byte_size: 1).headers,]
    end.value

    # https on a real bucket, http on floci.
    assert_equal ["from a worker", "from", "text/plain", nil, backend.tls ? "https" : "http",
                  { "Content-Type" => "text/plain", "Content-Length" => "1" },], result
  ensure
    Monk::Storage.reset!
  end

  # check against a real server: read-only, so the rules it reads are set
  # here, and removed again so no other test sees them.
  CORS = <<~XML.freeze
    <CORSConfiguration><CORSRule><AllowedOrigin>https://app.monkrb.org</AllowedOrigin>
    <AllowedMethod>PUT</AllowedMethod><AllowedHeader>content-type</AllowedHeader></CORSRule></CORSConfiguration>
  XML
  LIFECYCLE = <<~XML.freeze
    <LifecycleConfiguration><Rule><ID>expire-tmp</ID><Filter><Prefix>tmp/</Prefix></Filter>
    <Status>Enabled</Status><Expiration><Days>1</Days></Expiration></Rule></LifecycleConfiguration>
  XML

  def test_check_a_bucket_without_rules_names_both
    remove_rules
    error = assert_raises(Monk::Storage::CheckError) { backend.check(origin: "https://app.monkrb.org") }

    assert_includes error.message, "CORS rule doesn't let a page on https://app.monkrb.org PUT"
    assert_includes error.message, "no enabled lifecycle rule expires tmp/"
  end

  def test_check_a_bucket_with_both_rules
    bucket_rule(backend, "cors", CORS)
    bucket_rule(backend, "lifecycle", LIFECYCLE)

    assert_includes backend.check(origin: "https://app.monkrb.org"), "may PUT uploads to it, and tmp/ expires"
    error = assert_raises(Monk::Storage::CheckError) { backend.check(origin: "https://other.monkrb.org") }
    assert_includes error.message, "https://other.monkrb.org"
    assert_equal [], backend_keys, "nothing was written"
  ensure
    remove_rules
  end

  def test_check_with_a_wrong_secret_is_a_request_error
    error = assert_raises(Monk::Storage::RequestError) do
      backend.with(secret_key: "wrong").check(origin: "https://app.monkrb.org")
    end
    assert_includes error.message, "403"
  end

  private

  def remove_rules
    bucket_request(backend, "DELETE", query: { "cors" => "" })
    bucket_request(backend, "DELETE", query: { "lifecycle" => "" })
  end

  def backend_keys
    bucket_request(backend, "GET", query: { "list-type" => "2" }).body.scan(%r{<Key>([^<]*)</Key>}).flatten
  end
end
