# Passwordless login by email link (Monk::Auth).
Monk::Generator.define(:auth) do
  summary "Passwordless magic-link login"
  installed_if "config/auth.rb"
  depends_on :postgres, :mail

  copy "config/auth.rb", "app/mailers/auth_mailer.rb", role: :wiring
  copy "app/views/mail/magic_link.erb", "app/views/auth/login.erb", role: :view
  copy "app/routes/auth.rb", role: :example
  copy "test/auth_test.rb", role: :test
  migration "create_auth_tables"

  env :development, { "AUTH_SECRET" => "change-me-dev-secret" }
  env :test, { "AUTH_SECRET" => "change-me-test-secret" }
  env :example, { "AUTH_SECRET" => "change-me" }

  setup_section "auth/setup.md"
  agents_section "auth/agents.md"
  set_before_production "AUTH_SECRET", "placeholder in .env — replace it", placeholder: true
  example "auth-routes", todo: lambda { |installed|
    if installed.include?("jobs")
      "uncomment, keep the rate limit; send with Monk::Auth::SendLoginLink (jobs is installed)"
    else
      "uncomment, keep the rate limit, and list your redirects in config/auth.rb"
    end
  }
  closing 'Then turn on the login routes: app/routes/auth.rb, block "auth-routes" ' \
          "(keep the rate limit — AGENTS.md, auth, says why)."
end
