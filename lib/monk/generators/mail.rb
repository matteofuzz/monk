# Email over SMTP (Monk::Mail); printed to the console in development.
Monk::Generator.define(:mail) do
  summary "Email over SMTP (log:// in development)"
  installed_if "config/mail.rb"

  copy "config/mail.rb", role: :wiring
  copy "app/mailers/app_mailer.rb", "app/routes/mail.rb", role: :example
  copy "app/views/mail/welcome.erb", role: :view
  copy "test/mail_test.rb", role: :test

  gem %(gem "net-smtp", "~> 0.5" # Monk::Mail's smtp:// transport)
  env :development, { "MAIL_FROM" => ->(app) { %("#{app} <no-reply@localhost>") } }
  env :test, { "MAIL_URL" => "log://", "MAIL_FROM" => ->(app) { %("#{app} <no-reply@localhost>") } }
  env :example, { "MAIL_URL" => "smtp://user:password@smtp.example.com:587",
                  "MAIL_FROM" => ->(app) { %("#{app} <no-reply@example.com>") }, }

  setup_section "mail/setup.md"
  agents_section "mail/agents.md"
  set_before_production "MAIL_URL", "unset = printed to the console in development"
  set_before_production "MAIL_FROM", "a sender on a domain verified with your provider"
  example "mail-welcome", todo: lambda { |installed|
    "uncomment and adapt#{"; send it with deliver_later, jobs is installed" if installed.include?("jobs")}"
  }
end
