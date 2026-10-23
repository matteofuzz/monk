require_relative "test_helper"
require "monk/storage"

class StorageTokenTest < Minitest::Test
  TOKEN = Monk::Storage::Token
  PAYLOAD = { m: "PUT", k: "tmp/a", e: 1_800_000_000, l: 5, t: "image/png" }.freeze

  def test_round_trip
    assert_equal PAYLOAD, TOKEN.verify(TOKEN.sign(PAYLOAD, "secret"), "secret")
  end

  # Path-safe: it goes in /_monk/storage/<token> unescaped.
  def test_is_url_safe
    assert_match(/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/, TOKEN.sign(PAYLOAD, "secret"))
  end

  def test_the_same_payload_signs_the_same_token
    assert_equal TOKEN.sign(PAYLOAD, "secret"), TOKEN.sign(PAYLOAD.dup, "secret")
  end

  def test_another_secret_is_refused
    assert_nil TOKEN.verify(TOKEN.sign(PAYLOAD, "secret"), "other")
  end

  # Changing the payload (a bigger length, another key) breaks the signature.
  def test_a_changed_payload_is_refused
    body, signature = TOKEN.sign(PAYLOAD, "secret").split(".")
    forged = TOKEN.encode(JSON.generate(PAYLOAD.merge(l: 5_000_000)))

    assert_nil TOKEN.verify("#{forged}.#{signature}", "secret")
    assert_nil TOKEN.verify("#{body}.#{signature.reverse}", "secret")
  end

  def test_malformed_tokens_are_refused
    token = TOKEN.sign(PAYLOAD, "secret")
    ["", ".", "abc", "#{token}.x", token.delete("."), "#{token}=", "a b.c", "!!!.???"].each do |bad|
      assert_nil TOKEN.verify(bad, "secret"), bad.inspect
    end
  end

  # A correctly signed body that isn't a JSON object still isn't a payload.
  def test_a_signed_non_object_is_refused
    body = TOKEN.encode("[1,2]")
    signature = TOKEN.encode(OpenSSL::HMAC.digest("SHA256", "secret", body))

    assert_nil TOKEN.verify("#{body}.#{signature}", "secret")
  end
end
