# Loads everything the app runs on: the settings, each Monk module's config,
# then the app's own code under app/. Required by config.ru and the tests;
# it never boots the app itself (that's config.ru's Monk.boot).
require_relative "settings"

# The app's code, one directory per role, in the order they call each
# other: presenters read models, helpers, mailers and broadcasts use both,
# and jobs call all of them. Everything is loaded here, before Monk.boot
# freezes the app -- nothing can be loaded later from a worker Ractor.
#
# The order only matters for code that runs while a file loads (a
# superclass, a constant in a class body, a Monk::Context.include): such a
# file require_relative's what it needs first. Code inside methods runs
# later, so it may use any role, even one loaded after it. See Monk's
# docs/guides/scaffolding.md, "Where code goes".
%w[models presenters helpers mailers broadcasts jobs].each do |role|
  Dir[File.expand_path("../app/#{role}/**/*.rb", __dir__)].sort.each { |file| require file }
end
