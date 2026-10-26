require_relative "test_helper"
require "open3"

# require "digest" alone loads Digest::SHA1/SHA256 on first use, through
# Digest.const_missing. Loading one defines its constant a step before it
# attaches the metadata #digest reads, so a Ractor running in parallel
# that sees the constant in between raises "Digest::Base cannot be
# directly inherited in Ruby" -- a WebSocket handshake did, in a connect
# storm right after boot. Each library that hashes from a Ractor loads its
# digest class up front instead. Each case runs in a fresh Ruby, since this
# suite has loaded every digest class already.
class DigestPreloadTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  # Ractors wait for the constant to appear and call it at once, while one
  # more names it first: the window a lazy load leaves open. Prints how
  # many raised, then the first error.
  RACE = <<~RUBY.freeze
    name = ARGV.fetch(0).to_sym
    racers = 6.times.map do
      Ractor.new(name) do |name|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        until Digest.const_defined?(name, false)
          raise "Digest::\#{name} never appeared" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Thread.pass
        end
        Digest.const_get(name).digest("x")
        nil
      rescue => e
        "\#{e.class}: \#{e.message}"
      end
    end
    first = Ractor.new(name) do |name|
      Digest.const_get(name).digest("x")
      nil
    rescue => e
      "\#{e.class}: \#{e.message}"
    end
    errors = (racers << first).filter_map(&:value)
    print errors.size, " ", errors.first
  RUBY

  def test_websocket_handshake_digest_is_ready_before_any_ractor
    assert_equal "0 ", race("monk/websocket", "SHA1")
  end

  # Monk::Auth hashes login tokens from web worker and connection Ractors.
  def test_auth_token_digest_is_ready_before_any_ractor
    assert_equal "0 ", race("monk/auth", "SHA256")
  end

  # Monk::Assets hashes each file per request in development, from worker
  # Ractors: a page's first load asks for its stylesheet and script at once.
  def test_assets_etag_digest_is_ready_before_any_ractor
    assert_equal "0 ", race("monk/assets", "SHA256")
  end

  # The file backend hashes each put from worker Ractors (its etag).
  def test_storage_file_backend_digest_is_ready_before_any_ractor
    assert_equal "0 ", race("monk/storage", "MD5")
  end

  # The S3 backend's SigV4 hashes every request it signs.
  def test_storage_sig_v4_digest_is_ready_before_any_ractor
    assert_equal "0 ", race("monk/storage", "SHA256")
  end

  private

  def race(feature, digest_class)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-r", feature, "-e", RACE, digest_class)
    assert status.success?, err
    out
  end
end
