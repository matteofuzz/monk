require_relative "test_helper"
require "monk/storage"

class StorageConfigTest < Minitest::Test
  FILE = Monk::Storage::Backends::File
  S3 = Monk::Storage::Backends::S3
  HETZNER = "s3://AKID:hunter2@media?endpoint=fsn1.your-objectstorage.com&region=fsn1".freeze

  def teardown
    Monk::Storage.reset!
  end

  def backend_for(url, secret: nil)
    Monk::Storage.configure(url: url, secret: secret)
    Monk::Storage.config[:backend]
  end

  # The ADR's table, row by row (docs/adr/0018-storage-s3-compatible-direct-upload.md).
  def test_no_url_means_local_files_per_environment_in_development_and_test
    %w[development test].each do |env|
      with_settings do
        with_monk_env(env) do
          assert_equal File.expand_path("storage/#{env}"), backend_for(nil).root, env
          assert_equal File.expand_path("storage/#{env}"), backend_for("").root, env
        end
      end
    end
  end

  # On hosts whose disk is replaced on deploy, a fallback to local files
  # would lose every upload, so forgetting STORAGE_URL fails the boot.
  def test_no_url_raises_in_staging_and_production
    %w[staging production].each do |env|
      with_settings do
        with_monk_env(env) do
          error = assert_raises(Monk::Storage::MissingStorageUrlError, env) { backend_for(nil, secret: "s") }
          assert_match(/STORAGE_URL/, error.message)
          assert_includes error.message, "MONK_ENV=#{env}"
        end
      end
    end
  end

  def test_file_url_with_a_relative_directory
    assert_equal FILE.new(root: File.expand_path("tmp/uploads"), secret: Monk::Storage::DEVELOPMENT_SECRET),
      backend_for("file://tmp/uploads")
  end

  def test_file_url_with_an_absolute_directory
    assert_equal "/var/lib/app/storage", backend_for("file:///var/lib/app/storage").root
  end

  # Worker Ractors must not depend on the current directory.
  def test_file_root_is_expanded_at_configure
    root = Dir.mktmpdir do |dir|
      Dir.chdir(dir) { backend_for("file://storage").root }
    end

    assert_equal "storage", File.basename(root)
    assert_predicate Pathname.new(root), :absolute?
    refute_equal File.expand_path("storage"), root
  end

  def test_file_url_is_allowed_in_production_with_a_secret
    with_settings do
      with_monk_env("production") do
        backend = backend_for("file:///srv/volume", secret: "prod-secret")

        assert_equal "/srv/volume", backend.root
        assert_equal "prod-secret", backend.secret
      end
    end
  end

  def test_s3_url
    assert_equal S3.new(bucket: "media", endpoint: "fsn1.your-objectstorage.com", region: "fsn1",
      access_key: "AKID", secret_key: "hunter2", path_style: false, tls: true,), backend_for(HETZNER)
  end

  def test_s3_endpoint_may_carry_a_port_and_https
    backend = backend_for("s3://k:s@media?endpoint=https://s3.example.test:8443/&region=eu")

    assert_equal "s3.example.test:8443", backend.endpoint
    assert backend.tls
  end

  def test_s3_path_style
    assert backend_for("#{HETZNER}&path_style=1").path_style
    refute backend_for("#{HETZNER}&path_style=0").path_style
  end

  # Monk's own suite runs the S3 backend against a local floci over http.
  def test_s3_http_endpoint_for_a_local_server
    backend = backend_for("s3://test:test@monk-test?endpoint=http://127.0.0.1:4566&region=us-east-1&path_style=1")

    assert_equal "127.0.0.1:4566", backend.endpoint
    refute backend.tls
  end

  def test_s3_http_endpoint_is_refused_in_staging_and_production
    %w[staging production].each do |env|
      with_settings do
        with_monk_env(env) do
          error = assert_raises(Monk::Storage::InvalidStorageUrlError, env) do
            backend_for("s3://k:s@media?endpoint=http://s3.internal:9000&region=eu")
          end
          assert_includes error.message, "MONK_ENV=#{env}"
        end
      end
    end
  end

  # AWS secret keys often contain / and +: percent-encoded in the URL.
  def test_s3_credentials_are_percent_decoded
    backend = backend_for("s3://AK%2FID:wJal%2FrXU%2Bt%40x@media?endpoint=s3.example.test&region=eu")

    assert_equal "AK/ID", backend.access_key
    assert_equal "wJal/rXU+t@x", backend.secret_key
  end

  def test_scheme_is_case_insensitive
    assert_instance_of S3, backend_for(HETZNER.sub("s3", "S3"))
    assert_instance_of FILE, backend_for("FILE://tmp/uploads")
  end

  # An S3 backend doesn't sign anything with STORAGE_SECRET.
  def test_s3_never_needs_the_secret
    with_settings do
      with_monk_env("production") do
        assert_instance_of S3, backend_for(HETZNER)
      end
    end
  end

  def test_unknown_scheme_raises_naming_the_supported_ones
    error = assert_raises(Monk::Storage::InvalidStorageUrlError) { backend_for("gcs://bucket") }

    assert_match(/file:/, error.message)
    assert_match(/s3:/, error.message)
  end

  def test_invalid_urls_raise
    [
      "not a url",
      "file://",
      "file://storage?x=1",
      "s3://",
      "s3://k:s@media?region=eu",
      "s3://k:s@media?endpoint=s3.example.test",
      "s3://k:s@media?endpoint=s3.example.test&region=",
      "s3://k:s@media?endpoint=s3.example.test&region=eu&tls=1",
      "s3://k:s@media?endpoint=s3.example.test&region=eu&path_style=yes",
      "s3://k:s@media?endpoint=ftp://s3.example.test&region=eu",
      "s3://k:s@media?endpoint=s3.example.test/prefix&region=eu",
      "s3://media?endpoint=s3.example.test&region=eu",
      "s3://k@media?endpoint=s3.example.test&region=eu",
      "s3://k:s@Media?endpoint=s3.example.test&region=eu",
      "s3://k:s@ab?endpoint=s3.example.test&region=eu",
      "s3://k:s@media:9000?endpoint=s3.example.test&region=eu",
      "s3://k:s@media/folder?endpoint=s3.example.test&region=eu",
      "s3://k:se/cret@media?endpoint=s3.example.test&region=eu",
    ].each do |url|
      assert_raises(Monk::Storage::InvalidStorageUrlError, url) { backend_for(url) }
    end
  end

  # The URL carries the secret key; an error message must never echo it.
  def test_errors_never_include_the_secret_key
    error = assert_raises(Monk::Storage::InvalidStorageUrlError) { backend_for("#{HETZNER}&path_style=yes") }

    refute_includes error.message, "hunter2"
    assert_includes error.message, "AKID:***@media"
  end

  def test_backends_never_show_their_secrets
    s3 = backend_for(HETZNER)
    file = backend_for("file://tmp/uploads", secret: "file-secret")

    refute_includes s3.inspect, "hunter2"
    refute_includes s3.to_s, "hunter2"
    assert_includes s3.inspect, "AKID:***@media"
    refute_includes file.inspect, "file-secret"
    refute_includes file.to_s, "file-secret"
  end

  def test_file_secret_defaults_to_a_fixed_value_in_development_and_test
    %w[development test].each do |env|
      with_settings do
        with_monk_env(env) do
          assert_equal Monk::Storage::DEVELOPMENT_SECRET, backend_for(nil).secret, env
          assert_equal Monk::Storage::DEVELOPMENT_SECRET, backend_for(nil, secret: "").secret, env
          assert_equal "mine", backend_for(nil, secret: "mine").secret, env
        end
      end
    end
  end

  # The file backend's links would be signed with a value anyone can read
  # in Monk's source.
  def test_file_without_a_secret_raises_in_staging_and_production
    %w[staging production].each do |env|
      with_settings do
        with_monk_env(env) do
          error = assert_raises(Monk::Storage::MissingStorageSecretError, env) { backend_for("file:///srv/volume") }
          assert_match(/STORAGE_SECRET/, error.message)
          assert_includes error.message, "MONK_ENV=#{env}"
        end
      end
    end
  end

  def test_config_is_nil_until_configured
    assert_nil Monk::Storage.config
  end

  def test_a_failed_configure_keeps_no_config
    assert_raises(Monk::Storage::InvalidStorageUrlError) { backend_for("gcs://bucket") }

    assert_nil Monk::Storage.config
  end

  def test_registers_a_freeze_hook
    assert_includes Monk.freeze_hooks, Monk::Storage
  end

  def test_freeze_registry_without_configure_is_a_no_op
    Monk::Storage.freeze_registry!

    assert_nil Monk::Storage.config
  end

  # The regression the freeze hook exists for: an unfrozen config Hash
  # can't be read from a worker Ractor at all.
  def test_frozen_config_is_readable_from_a_worker_ractor
    Monk::Storage.configure(url: +HETZNER)
    Monk.freeze!

    result = Ractor.new do
      backend = Monk::Storage.config[:backend]
      [backend.bucket, backend.endpoint, backend.secret_key]
    end.value

    assert_equal ["media", "fsn1.your-objectstorage.com", "hunter2"], result
  end

  def test_frozen_file_config_is_readable_from_a_worker_ractor
    Monk::Storage.configure(url: +"file://tmp/uploads", secret: +"s")
    Monk.freeze!

    result = Ractor.new { Monk::Storage.config[:backend].then { |b| [b.root, b.secret] } }.value

    assert_equal [File.expand_path("tmp/uploads"), "s"], result
  end
end
