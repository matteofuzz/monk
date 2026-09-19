source "https://rubygems.org"

gemspec

# The demo app (config.ru, bin/server) is served by kino, and so is the
# Docker image. Deliberately not a gemspec development dependency: those
# land in Bundler's :development group, which the image leaves out
# (BUNDLE_WITHOUT in the Dockerfile) along with pg, redis, rqrcode,
# minitest, rake and rubocop.
gem "kino"
