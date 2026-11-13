require_relative "test_helper"
require "json"
require "monk/push"

# Web push's crypto, written over OpenSSL (docs/plan-pwa-push.md, B2):
# RFC 8291's message encryption, checked against the RFC's own test vector
# and against a browser-side decryption; RFC 8292's VAPID header; P-256 keys
# from raw bytes; all of it inside a worker Ractor too.
class PushCryptoTest < Minitest::Test
  include PushTestHelpers

  B64 = Monk::Push::Base64Url

  # RFC 8291, Appendix A.
  RFC = Ractor.make_shareable({
    plaintext: "When I grow up, I want to be a watermelon",
    as_private: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
    as_public: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
    ua_private: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
    ua_public: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
    salt: "DGv6ra1nlYgDCS1FRnbzlw",
    auth: "BTBZMqHH6r4Tts7J_aSIgg",
    body: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8w" \
          "EqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
  })

  # --- encryption (RFC 8291) ---

  def test_the_rfc_8291_test_vector
    server_key = Monk::Push::Keys.private_pkey(B64.decode(RFC[:as_private]))

    body = Monk::Push::Encryption.encrypt(RFC[:plaintext], p256dh: RFC[:ua_public], auth: RFC[:auth],
      salt: B64.decode(RFC[:salt]), server_key: server_key,)

    assert_equal RFC[:body], B64.encode(body)
  end

  # The decryption below is a browser's side; it must agree with the RFC
  # before it can vouch for messages made with random salts and keys.
  def test_the_browser_side_decrypts_the_rfc_body
    assert_equal RFC[:plaintext], decrypt(B64.decode(RFC[:body]), RFC[:ua_private], RFC[:ua_public], RFC[:auth])
  end

  def test_a_message_round_trips_with_a_fresh_salt_and_key_each_time
    ua_private, ua_public, auth = subscription

    first = Monk::Push::Encryption.encrypt("hi", p256dh: ua_public, auth: auth)
    second = Monk::Push::Encryption.encrypt("hi", p256dh: ua_public, auth: auth)

    refute_equal first, second
    refute_equal first[0, 16], second[0, 16], "a new salt"
    refute_equal first[21, 65], second[21, 65], "a new server key"
    assert_equal "hi", decrypt(first, ua_private, ua_public, auth)
  end

  def test_the_largest_payload_fills_one_4096_byte_record
    ua_private, ua_public, auth = subscription
    payload = "x" * Monk::Push::Encryption::MAX_PAYLOAD

    body = Monk::Push::Encryption.encrypt(payload, p256dh: ua_public, auth: auth)

    assert_equal 3993, Monk::Push::Encryption::MAX_PAYLOAD
    assert_equal 4096, body.bytesize
    assert_equal payload, decrypt(body, ua_private, ua_public, auth)
    error = assert_raises(Monk::Push::PayloadTooLargeError) do
      Monk::Push::Encryption.encrypt("#{payload}x", p256dh: ua_public, auth: auth)
    end
    assert_includes error.message, "at most 3993 bytes, got 3994"
  end

  def test_payload_size_counts_bytes_not_characters
    _ua_private, ua_public, auth = subscription

    assert_raises(Monk::Push::PayloadTooLargeError) do
      Monk::Push::Encryption.encrypt("é" * 2000, p256dh: ua_public, auth: auth)
    end
  end

  def test_unusable_subscription_keys
    _ua_private, ua_public, auth = subscription
    off_curve = B64.encode("\x04".b + ("\x01".b * 64))

    { [ua_public, B64.encode("x" * 8)] => "auth is 16 bytes, got 8",
      ["not base64!", auth] => "not base64url",
      [B64.encode("\x04".b + ("\x01".b * 10)), auth] => "65 bytes",
      [off_curve, auth] => "not a point on P-256", }.each do |(p256dh, auth_key), message|
      error = assert_raises(Monk::Push::InvalidSubscriptionError, p256dh) do
        Monk::Push::Encryption.encrypt("hi", p256dh: p256dh, auth: auth_key)
      end
      assert_includes error.message, message
    end
  end

  # --- VAPID (RFC 8292) ---

  def test_the_vapid_header_carries_a_jwt_the_public_key_verifies
    pair = Monk::Push::Keys.generate

    header = vapid("https://fcm.googleapis.com/fcm/send/abc123", pair, now: 1_000)

    jwt, public_key = header.match(/\Avapid t=([^,]+), k=(\S+)\z/).captures
    assert_equal pair[:public_key], public_key
    head, claims, signature = jwt.split(".")
    assert_equal({ "typ" => "JWT", "alg" => "ES256" }, JSON.parse(B64.decode(head)))
    expected = { "aud" => "https://fcm.googleapis.com", "exp" => 1_000 + (12 * 3600), "sub" => "mailto:ops@shop.test" }
    assert_equal expected, JSON.parse(B64.decode(claims))
    assert_equal 64, B64.decode(signature).bytesize
    assert verifies?(pair[:public_key], "#{head}.#{claims}", B64.decode(signature))
    refute verifies?(Monk::Push::Keys.generate[:public_key], "#{head}.#{claims}", B64.decode(signature))
  end

  def test_the_audience_is_the_endpoints_origin
    { "https://updates.push.services.mozilla.com/wpush/v2/x" => "https://updates.push.services.mozilla.com",
      "https://web.push.apple.com:443/QF8" => "https://web.push.apple.com",
      "https://push.example:8443/p/1?x=1" => "https://push.example:8443",
      "http://127.0.0.1:9999/push/1" => "http://127.0.0.1:9999", }.each do |endpoint, origin|
      assert_equal origin, Monk::Push::Vapid.audience(endpoint)
    end
    ["ftp://push.example/x", "not a url", "/relative", ""].each do |endpoint|
      assert_raises(ArgumentError, endpoint) { Monk::Push::Vapid.audience(endpoint) }
    end
  end

  def test_expires_in_stays_within_the_24_hours_push_services_take
    pair = Monk::Push::Keys.generate

    claims = JSON.parse(B64.decode(vapid("https://p.test/1", pair, now: 0, expires_in: 60)[/t=[^.]+\.([^.]+)\./, 1]))
    assert_equal 60, claims["exp"]
    [0, (24 * 3600) + 1, 1.5].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { vapid("https://p.test/1", pair, expires_in: bad) }
    end
  end

  # --- keys ---

  def test_a_generated_pair_is_raw_p256_in_base64url
    pair = Monk::Push::Keys.generate

    assert_equal 65, B64.decode(pair[:public_key]).bytesize
    assert_equal 4, B64.decode(pair[:public_key]).getbyte(0)
    assert_equal 32, B64.decode(pair[:private_key]).bytesize
    assert_equal pair[:public_key], Monk::Push::Keys.public_key_for(pair[:private_key])
    refute_equal pair, Monk::Push::Keys.generate
  end

  def test_the_rfc_private_key_derives_the_rfc_public_key
    assert_equal RFC[:as_public], Monk::Push::Keys.public_key_for(RFC[:as_private])
    assert_equal RFC[:ua_public], Monk::Push::Keys.public_key_for(RFC[:ua_private])
  end

  def test_keys_of_the_wrong_size_or_not_on_the_curve
    assert_raises(ArgumentError) { Monk::Push::Keys.public_key_for(B64.encode("x" * 31)) }
    assert_raises(ArgumentError) { Monk::Push::Keys.public_key_for(B64.encode("\0".b * 32)) }
    assert_raises(ArgumentError) { Monk::Push::Keys.public_key_for(B64.encode("\xFF".b * 32)) }
    assert_raises(ArgumentError) { Monk::Push::Keys.public_pkey("\x04".b + ("\x01".b * 64)) }
    assert_raises(ArgumentError) { Monk::Push::Keys.public_pkey("\x02".b + ("\x01".b * 64)) }
  end

  def test_base64url_is_strict_but_takes_padding
    assert_equal "\xFB\xFF".b, B64.decode("-_8")
    assert_equal "\xFB\xFF".b, B64.decode("-_8=")
    assert_equal "-_8", B64.encode("\xFB\xFF".b)
    ["a+b", "a/b", "a b", "a"].each { |bad| assert_raises(ArgumentError, bad) { B64.decode(bad) } }
  end

  # --- Ractors ---

  # A job worker is a Ractor: everything above has to run in one, several
  # at once.
  def test_encryption_and_vapid_run_in_worker_ractors
    ua_private, ua_public, auth = subscription
    pair = Monk::Push::Keys.generate
    inputs = Ractor.make_shareable([ua_public, auth, pair[:public_key], pair[:private_key]])

    results = Array.new(4) do
      Ractor.new(inputs) do |(p256dh, auth_key, public_key, private_key)|
        Array.new(25) do
          [Monk::Push::Encryption.encrypt("hi", p256dh: p256dh, auth: auth_key),
           Monk::Push::Vapid.authorization("https://p.test/1", public_key: public_key, private_key: private_key,
             contact: "mailto:ops@shop.test",),]
        end
      end
    end.flat_map(&:value)

    assert_equal 100, results.size
    results.each do |body, header|
      assert_equal "hi", decrypt(body, ua_private, ua_public, auth)
      head, claims, signature = header[/t=([^,]+)/, 1].split(".")
      assert verifies?(pair[:public_key], "#{head}.#{claims}", B64.decode(signature))
    end
  end

  private

  # A browser's subscription: its private key (to decrypt), and the
  # p256dh and auth it would send, base64url.
  def subscription
    key = OpenSSL::PKey::EC.generate("prime256v1")
    [B64.encode(Monk::Push::Keys.raw_private(key)), B64.encode(Monk::Push::Keys.raw_public(key)),
     B64.encode(SecureRandom.random_bytes(16)),]
  end

  def vapid(endpoint, pair, now: Time.now.to_i, expires_in: Monk::Push::Vapid::EXPIRES_IN)
    Monk::Push::Vapid.authorization(endpoint, public_key: pair[:public_key], private_key: pair[:private_key],
      contact: "mailto:ops@shop.test", now: now, expires_in: expires_in,)
  end
end
