require_relative "test_helper"
require "monk/push"

# Monk::Push.configure (docs/plan-pwa-push.md, B1): a VAPID pair that
# doesn't belong together, or a missing contact, fails the boot instead of
# every push service refusing every message later.
class PushConfigTest < Minitest::Test
  def setup
    @pair = Monk::Push::Keys.generate
  end

  def teardown
    Monk::Push.reset!
  end

  def test_configure_keeps_a_shareable_config
    configure

    assert Monk::Push.configured?
    assert_equal @pair[:public_key], Monk::Push.public_key
    assert_equal :primary, Monk::Push.config[:db_name]
    assert Ractor.shareable?(Monk::Push.config)
  end

  def test_a_private_key_from_another_pair_fails_the_boot
    error = assert_raises(Monk::Push::InvalidKeyError) do
      configure(private_key: Monk::Push::Keys.generate[:private_key])
    end
    assert_includes error.message, "doesn't go with VAPID_PUBLIC_KEY"
  end

  def test_missing_or_malformed_keys_fail_the_boot
    { { public_key: nil } => "public_key:) is missing (VAPID_PUBLIC_KEY)",
      { private_key: "" } => "private_key:) is missing (VAPID_PRIVATE_KEY)",
      { private_key: "not-a-key" } => "isn't a P-256 private key",
      { public_key: "#{@pair[:public_key]}x" } => "doesn't go with", }.each do |override, message|
      error = assert_raises(Monk::Push::InvalidKeyError, override.inspect) { configure(**override) }
      assert_includes error.message, message
    end
  end

  def test_the_contact_is_a_mailto_or_https_url
    ["mailto:ops@shop.com", "https://shop.com/contact"].each { |contact| configure(contact: contact) }
    [nil, "", "ops@shop.com", "ftp://shop.com", "mailto:nobody"].each do |contact|
      error = assert_raises(ArgumentError, contact.inspect) { configure(contact: contact) }
      assert_includes error.message, "VAPID_CONTACT"
    end
  end

  # Apple answers 403 BadJwtToken to a contact on a placeholder domain
  # (an iPhone, with mailto:push@shop.example): outside development and
  # test that fails the boot.
  def test_a_contact_no_one_can_be_reached_at_fails_the_boot_in_production
    unreachable = ["mailto:push@shop.example", "https://shop.test", "http://localhost:9292", "https://127.0.0.1",
                   "mailto:ops@example.com", "https://app.localhost",]
    with_settings do
      with_env("MONK_ENV", "production") do
        unreachable.each do |contact|
          error = assert_raises(ArgumentError, contact) { configure(contact: contact) }
          assert_includes error.message, "Apple refuses every push", contact
        end
        configure(contact: "https://shop.com")
        configure(contact: "mailto:ops@example.org.uk")
      end
    end
  end

  def test_in_development_an_unreachable_contact_is_a_warning
    with_log do |dir|
      with_settings do
        with_monk_env("development") do
          configure(contact: "http://localhost:9292")

          assert Monk::Push.configured?
          assert_includes File.read(File.join(dir, "development.log")), "WARN Monk::Push.configure(contact:)"
        end
      end
    end
  end

  def test_reading_the_key_before_configure_says_so
    assert_raises(Monk::Push::NotConfiguredError) { Monk::Push.public_key }
  end

  def test_the_subscribe_path_defaults_and_must_be_a_path
    configure
    assert_equal "/push/subscription", Monk::Push.config[:path]

    configure(path: "/me/push")
    assert_equal "/me/push", Monk::Push.config[:path]
    assert_raises(ArgumentError) { configure(path: "push") }
  end

  # --- the page side ---

  def test_nothing_in_the_head_until_configured
    refute_includes Monk::Context.new({}).monk_head.to_s, "monk-push"
  end

  def test_the_head_gives_the_key_the_route_and_the_client
    configure(path: %(/push/"x))
    head = Monk::Context.new({}).monk_head.to_s

    assert_includes head, %(<meta name="monk-push-key" content="#{@pair[:public_key]}">)
    assert_includes head, %(<meta name="monk-push-url" content="/push/&quot;x">)
    assert_match(%r{<script type="module" src="/_monk/push/push\.js(\?v=\h+)?"></script>}, head)
  end

  def test_the_client_is_served_from_the_gem
    with_assets({}) do
      app = Class.new(Monk::Base) { get("/") { "home" } }
      app.assets(Monk::Assets.root)
      boot_quietly(app)

      %w[push.js state.js].each do |file|
        status, headers, = app.call(env_for("GET", "/_monk/push/#{file}"))
        assert_equal [200, "text/javascript; charset=utf-8"], [status, headers["content-type"]], file
      end
    end
  end

  private

  def configure(**override)
    Monk::Push.configure(db_name: :primary, contact: "mailto:ops@shop.com", **@pair, **override)
  end
end
