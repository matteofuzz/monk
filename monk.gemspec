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

  spec.files = Dir.chdir(__dir__) { `git ls-files -z lib LICENSE.txt README.md`.split("\x0") }
  spec.require_paths = ["lib"]

  spec.add_dependency "rack", "~> 3.0"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "kino"
end
