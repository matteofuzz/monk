# The bare app `monk new` writes: every other module is added on top of it.
Monk::Generator.define(:base) do
  summary "The bare app: routes, views, static files, tests, SETUP.md and AGENTS.md"
  installed_if "config/load.rb"

  copy "Gemfile", "config.ru", "config/settings.rb", "config/load.rb", "app/app.rb", ".ruby-version",
    ".gitignore", ".dockerignore", "Dockerfile", "public/css/app.css", "public/js/app.js", "Rakefile",
    "CLAUDE.md", role: :wiring
  copy "bin/server", role: :wiring, executable: true
  copy "app/views/layouts/app.erb", "app/views/index.erb", role: :view
  # Every role directory, empty, so the tree shows where each kind of code
  # goes (docs/adr/0015), and app/routes/ for the routes modules add.
  copy(*%w[models presenters helpers mailers broadcasts jobs routes].map { |role| "app/#{role}/.keep" }, role: :wiring)
  copy "test/test_helper.rb", "test/app_test.rb", role: :test

  setup_section "base/setup.md"
  agents_section "base/agents.md"
  next_step "bin/server", note: "http://localhost:9292"
end
