require_relative "lib/monk/version"

Gem::Specification.new do |spec|
  # Published as "monkrb", not "monk": that name has belonged since 2009 to
  # an unrelated, long-dead Sinatra-glue gem on rubygems.org. The code
  # itself keeps the Monk:: namespace and `require "monk"` -- an app's
  # Gemfile needs `gem "monkrb", require: "monk"`.
  spec.name = "monkrb"
  spec.version = Monk::VERSION
  spec.authors = ["Matteo Folin"]
  spec.email = ["matteo.folin@gmail.com"]

  spec.summary = "A light Ruby web framework designed to be fully Ractor-safe."
  spec.description = "Monk produces Rack 3 apps that are also Ractor.shareable?, so they can be " \
    "served in parallel across Ractor worker pools without silently losing that safety property."
  spec.homepage = "https://github.com/matteofuzz/monk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true",
  }

  spec.files = Dir.chdir(__dir__) { `git ls-files -z lib exe LICENSE.txt README.md CHANGELOG.md`.split("\x0") }
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["monk"]

  spec.add_dependency "rack", "~> 3.0"
  # Base64 stopped being a default gem in Ruby 3.4 (bundled instead) --
  # Monk::WebSocket::Handshake requires it directly for the RFC 6455
  # handshake, so unlike a persistence backend this isn't opt-in per app.
  spec.add_dependency "base64"

  # Persistence backends are opt-in (require "monk/persistence/pg"
  # explicitly), so their gems aren't runtime dependencies of monk itself --
  # an app that wants Monk::Persistence::Pg declares "pg" in its own
  # Gemfile. Still needed here to run monk's own test suite.
  spec.add_development_dependency "pg", "~> 1.5"

  # Same posture as pg above: Monk::WebSocket::RedisFanout is opt-in
  # (require "monk/websocket/redis_fanout" explicitly), so redis isn't a
  # runtime dependency of monk itself -- an app that wants cross-process
  # WebSocket fan-out declares "redis" in its own Gemfile.
  spec.add_development_dependency "redis", "~> 5.0"

  # Same posture as pg/redis above: Monk::Auth.log_dev_link's QR code is
  # opt-in (require "rqrcode" happens lazily inside the method, rescuing
  # LoadError), so it isn't a runtime dependency of monk itself -- an app
  # that wants the QR code declares it in its own Gemfile.
  spec.add_development_dependency "rqrcode", "~> 3.2"

  # Same posture again: Monk::Mail's smtp:// transport requires it when
  # configured, and it's been a bundled (not default) gem since Ruby 3.1,
  # so an app that sends over SMTP declares "net-smtp" in its own Gemfile.
  spec.add_development_dependency "net-smtp", "~> 0.5"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rubocop", "~> 1.90"

  # Headless Chrome over its debugging protocol, pure Ruby (no chromedriver,
  # no npm): drives the real-browser tests of Monk::Live's client JS.
  # Those tests skip when Chrome isn't installed.
  spec.add_development_dependency "ferrum", "~> 0.18"
end
