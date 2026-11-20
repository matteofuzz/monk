require_relative "../test_helper"
require "yaml"

# monk add deploy (docs/history/plan-forms.md C3): compose.yaml, the Caddyfile and
# .env.production.example, built from the modules installed, before or
# after it.
class GeneratorsDeployTest < Minitest::Test
  include GeneratorTestHelpers

  def test_alone_it_runs_the_app_behind_caddy
    with_new_app(:deploy) do |dest|
      assert_equal %w[web caddy], services(dest).keys
      assert_equal "shop", services(dest)["web"]["image"]
      assert_equal template("deploy/Caddyfile"), generated(dest, "Caddyfile")
      assert_equal %w[MONK_ENV PUBLIC_URL SITE_ADDRESS], env_keys(dest)
      assert File.executable?(File.join(dest, "bin/deploy_env"))
    end
  end

  def test_each_module_adds_its_services_and_settings
    with_new_app(:jobs, :live, :push, :redis, :storage, :deploy, options: { transport: "postgres" }) do |dest|
      assert_equal %w[web caddy postgres redis jobs ws], services(dest).keys
      assert_equal "shop", services(dest)["jobs"]["image"]
      assert_equal "bin/websocket_server", services(dest)["ws"]["command"]
      keys = env_keys(dest)
      %w[DB_HOST DB_PASSWORD POSTGRES_PASSWORD REDIS_URL MAIL_URL AUTH_SECRET JOBS_QUEUES WS_PORT
         STORAGE_URL VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY].each { |key| assert_includes keys, key }
      assert_includes generated(dest, ".env.production.example"), "DB_NAME=shop\n"
    end
  end

  def test_a_module_added_after_deploy_adds_its_part
    first = with_new_app(:deploy) do |dest|
      add_modules(dest, :jobs)
      add_modules(dest, :websocket, options: { transport: "postgres" })
      [services(dest).keys.sort, env_keys(dest).sort]
    end
    last = with_new_app(:jobs, :websocket, :deploy, options: { transport: "postgres" }) do |dest|
      [services(dest).keys.sort, env_keys(dest).sort]
    end

    assert_equal last, first
  end

  def test_without_deploy_no_module_writes_its_files
    with_new_app(:jobs) do |dest|
      refute File.exist?(File.join(dest, "compose.yaml"))
      refute File.exist?(File.join(dest, ".env.production.example"))
    end
  end

  def test_the_example_is_committed_and_the_real_file_is_not
    with_new_app(:deploy) do |dest|
      assert_includes generated(dest, ".gitignore").lines, "!/.env.production.example\n"
      assert_includes generated(dest, ".gitignore").lines, "/.env.*\n", ".env.production stays ignored"
    end
  end

  def test_deploy_env_fills_in_the_secrets_once
    with_new_app(:auth, :deploy) do |dest|
      out = deploy_env(dest)
      env = production_env(dest)

      assert_match(/\A\h{64}\z/, env["AUTH_SECRET"])
      assert_match(/\A\h{48}\z/, env["DB_PASSWORD"])
      assert_equal env["DB_PASSWORD"], env["POSTGRES_PASSWORD"]
      assert_equal 0o600, File.stat(File.join(dest, ".env.production")).mode & 0o777
      assert_includes out, "PUBLIC_URL=https://app.example.com", "lists what's still a placeholder"

      deploy_env(dest)
      assert_equal env, production_env(dest), "a second run changes nothing"
    end
  end

  private

  def services(dest) = YAML.safe_load(generated(dest, "compose.yaml")).fetch("services")

  def env_keys(dest) = generated(dest, ".env.production.example").scan(/^([A-Z_]+)=/).flatten

  def production_env(dest)
    generated(dest, ".env.production").scan(/^([A-Z_]+)=(.*)$/).to_h
  end

  def deploy_env(dest)
    out, status = Open3.capture2e(File.join(dest, "bin/deploy_env"), chdir: dest)
    assert status.success?, out
    out
  end
end
