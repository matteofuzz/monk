require_relative "test_helper"
require "monk/storage"

# Against AWS's published vectors (docs/plan-storage.md decision 10): the
# SigV4 test suite (awslabs/aws-c-auth, tests/aws-signing-test-suite/v4)
# and the S3 API reference's examples. A wrong byte anywhere in the
# canonical request changes the signature, so each one checks all of it.
class StorageSigV4Test < Minitest::Test
  SIG = Monk::Storage::SigV4

  # The test suite's context.json.
  SUITE = { access_key: "AKIDEXAMPLE", secret_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1", service: "service", }.freeze
  SUITE_NOW = Time.utc(2015, 8, 30, 12, 36, 0).to_i
  SUITE_HOST = { "Host" => "example.amazonaws.com" }.freeze

  # The S3 API reference's examples ("Examples: Signature Calculations").
  S3 = { access_key: "AKIAIOSFODNN7EXAMPLE", secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
         region: "us-east-1", }.freeze
  S3_NOW = Time.utc(2013, 5, 24).to_i
  S3_HOST = "examplebucket.s3.amazonaws.com".freeze

  def signature_of(authorization)
    authorization["authorization"][/, Signature=(\h{64})\z/, 1]
  end

  def query_signature_of(query)
    query[/&X-Amz-Signature=(\h{64})\z/, 1]
  end

  # get-vanilla
  def test_suite_get_vanilla
    headers = SIG.sign_headers(method: "GET", path: "/", headers: SUITE_HOST, payload_hash: SIG::EMPTY_PAYLOAD,
      credentials: SUITE, now: SUITE_NOW,)

    assert_equal "20150830T123600Z", headers["x-amz-date"]
    assert_equal "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " \
                 "SignedHeaders=host;x-amz-date, " \
                 "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", headers["authorization"]
  end

  def test_suite_get_vanilla_canonical_request_and_string_to_sign
    signed = SIG.canonical_headers(SUITE_HOST.merge("x-amz-date" => "20150830T123600Z"))
    request = SIG.canonical_request("GET", "/", "", signed, SIG::EMPTY_PAYLOAD)

    assert_equal <<~TEXT.chomp, request
      GET
      /

      host:example.amazonaws.com
      x-amz-date:20150830T123600Z

      host;x-amz-date
      e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    TEXT
    assert_equal <<~TEXT.chomp, SIG.string_to_sign(request, SUITE, "20150830T123600Z")
      AWS4-HMAC-SHA256
      20150830T123600Z
      20150830/us-east-1/service/aws4_request
      bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63
    TEXT
  end

  # get-vanilla, signed in the query string.
  def test_suite_get_vanilla_presigned
    query = SIG.presign(method: "GET", path: "/", headers: SUITE_HOST, expires_in: 3600, credentials: SUITE,
      now: SUITE_NOW, payload_hash: SIG::EMPTY_PAYLOAD,)

    assert_equal "X-Amz-Algorithm=AWS4-HMAC-SHA256&" \
                 "X-Amz-Credential=AKIDEXAMPLE%2F20150830%2Fus-east-1%2Fservice%2Faws4_request&" \
                 "X-Amz-Date=20150830T123600Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&" \
                 "X-Amz-Signature=e93c787ed7f371d5c6b165c1b38ede9550f4dce4144713e844b25b7192d3865d", query
  end

  # post-x-www-form-urlencoded, with the body's hash signed as a header.
  def test_suite_post_x_www_form_urlencoded
    body = Digest::SHA256.hexdigest("Param1=value1")
    headers = { "Content-Type" => "application/x-www-form-urlencoded", "Host" => "example.amazonaws.com",
                "Content-Length" => "13", "x-amz-content-sha256" => body, }

    signed = SIG.sign_headers(method: "POST", path: "/", headers: headers, payload_hash: body, credentials: SUITE,
      now: SUITE_NOW,)

    assert_includes signed["authorization"],
      "SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date,"
    assert_equal "d3875051da38690788ef43de4db0d8f280229d82040bfac253562e56c3f20e0b", signature_of(signed)
  end

  def test_suite_post_x_www_form_urlencoded_presigned
    headers = { "Content-Type" => "application/x-www-form-urlencoded", "Host" => "example.amazonaws.com",
                "Content-Length" => "13", }

    query = SIG.presign(method: "POST", path: "/", headers: headers, expires_in: 3600, credentials: SUITE,
      now: SUITE_NOW, payload_hash: Digest::SHA256.hexdigest("Param1=value1"),)

    assert_includes query, "&X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost&"
    assert_equal "89a40deed0f26f9461242825a082d2222717248abc7ab41f552ad84a94ad46e9", query_signature_of(query)
  end

  # get-vanilla-query-order-key-case: parameters sorted by name.
  def test_suite_query_parameters_are_sorted
    params = { "Param2" => "value2", "Param1" => "value1" }

    signed = SIG.sign_headers(method: "GET", path: "/", query: params, headers: SUITE_HOST,
      payload_hash: SIG::EMPTY_PAYLOAD, credentials: SUITE, now: SUITE_NOW,)
    query = SIG.presign(method: "GET", path: "/", query: params, headers: SUITE_HOST, expires_in: 3600,
      credentials: SUITE, now: SUITE_NOW, payload_hash: SIG::EMPTY_PAYLOAD,)

    assert_equal "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500", signature_of(signed)
    assert query.start_with?("Param1=value1&Param2=value2&X-Amz-Algorithm=")
    assert_equal "86012e2c9ad4d77369f5d81c11f75158aae4f895a085212cc6d3f923d300bed5", query_signature_of(query)
  end

  # S3 "GET Object": a ranged get, the empty body's hash signed.
  def test_s3_get_object
    headers = { "Host" => S3_HOST, "Range" => "bytes=0-9", "x-amz-content-sha256" => SIG::EMPTY_PAYLOAD }

    signed = SIG.sign_headers(method: "GET", path: "/test.txt", headers: headers, payload_hash: SIG::EMPTY_PAYLOAD,
      credentials: S3, now: S3_NOW,)

    assert_equal "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " \
                 "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " \
                 "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", signed["authorization"]
  end

  # S3 "PUT Object": the body's hash, and a key with a $ in it.
  def test_s3_put_object
    body = Digest::SHA256.hexdigest("Welcome to Amazon S3.")
    headers = { "Host" => S3_HOST, "Date" => "Fri, 24 May 2013 00:00:00 GMT",
                "x-amz-storage-class" => "REDUCED_REDUNDANCY", "x-amz-content-sha256" => body, }

    signed = SIG.sign_headers(method: "PUT", path: "/test$file.text", headers: headers, payload_hash: body,
      credentials: S3, now: S3_NOW,)

    assert_equal "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", signature_of(signed)
  end

  # S3 "GET Bucket Lifecycle": a subresource, a parameter with no value.
  def test_s3_get_bucket_lifecycle
    signed = SIG.sign_headers(method: "GET", path: "/", query: { "lifecycle" => "" },
      headers: { "Host" => S3_HOST, "x-amz-content-sha256" => SIG::EMPTY_PAYLOAD }, payload_hash: SIG::EMPTY_PAYLOAD,
      credentials: S3, now: S3_NOW,)

    assert_equal "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543", signature_of(signed)
  end

  # S3's presigned URL example: a day-long link, UNSIGNED-PAYLOAD.
  def test_s3_presigned_get
    query = SIG.presign(method: "GET", path: "/test.txt", headers: { "Host" => S3_HOST }, expires_in: 86_400,
      credentials: S3, now: S3_NOW,)

    assert_equal "X-Amz-Algorithm=AWS4-HMAC-SHA256&" \
                 "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&" \
                 "X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&" \
                 "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404", query
  end

  # Keys keep their "/"; S3 encodes a path once and never normalizes it.
  def test_path_encoding
    assert_equal "/bucket/tmp/a1.b_c-d~e", SIG.encode_path("/bucket/tmp/a1.b_c-d~e")
    assert_equal "/a%20b/c%2Bd/%24/%C3%A9", SIG.encode_path("/a b/c+d/$/é")
    assert_equal "/a/../b//c", SIG.encode_path("/a/../b//c")
  end

  def test_query_encoding
    assert_equal "a=b%20c&a%2Bb=%2F%3D%26", SIG.canonical_query("a+b" => "/=&", "a" => "b c")
    assert_equal "", SIG.canonical_query({})
  end

  def test_header_names_are_lowercased_and_values_trimmed
    assert_equal({ "a" => "x y z", "content-type" => "text/plain" },
      SIG.canonical_headers("Content-Type" => " text/plain ", "A" => "x   y\tz"),)
  end

  def test_presign_validates_expires_in
    [0, -1, (7 * 86_400) + 1, 1.5, "60"].each do |expires_in|
      assert_raises(ArgumentError, expires_in.inspect) do
        SIG.presign(method: "GET", path: "/", headers: SUITE_HOST, expires_in: expires_in, credentials: SUITE, now: 0)
      end
    end
  end

  # The S3 backend signs from worker Ractors (OpenSSL::HMAC and SHA-256
  # there, as the ADR's spike measured).
  def test_signing_from_a_worker_ractor
    credentials = Ractor.make_shareable(SUITE.dup)

    signature = Ractor.new(credentials, SUITE_NOW) do |creds, now|
      Monk::Storage::SigV4.sign_headers(method: "GET", path: "/", headers: { "Host" => "example.amazonaws.com" },
        payload_hash: Monk::Storage::SigV4::EMPTY_PAYLOAD, credentials: creds, now: now,)["authorization"]
    end.value

    assert signature.end_with?("Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
  end
end
