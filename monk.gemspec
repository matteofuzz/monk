require_relative "lib/monk/version"

Gem::Specification.new do |spec|
  spec.name = "monk"
  spec.version = Monk::VERSION
  spec.authors = ["Matteo Folin"]
  spec.email = ["matteo.folin@gmail.com"]

  spec.summary = "A minimalistic, Sinatra-style Ruby web framework, fully Ractor-safe."
  spec.description = "Monk produces Rack 3 apps that are also Ractor.shareable?, so they can be " \
    "served in parallel across Ractor worker pools without silently losing that safety property."
  spec.homepage = "https://github.com/matteofuzz/monk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir.chdir(__dir__) { `git ls-files -z lib exe LICENSE.txt README.md`.split("\x0") }
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

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "kino"
end
