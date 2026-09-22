# Two-stage build: the builder resolves and installs gems, the final image
# only keeps the installed bundle plus the app -- no compiler, no gem
# cache, in the image that actually runs. No system packages needed here:
# kino ships as precompiled platform gems, and a plain `bundle install`
# (Gemfile.lock committed) already resolves every compatible platform, not
# just the machine that ran it -- nothing to add by hand before building on
# a different host (docs/guides/deploying.md, "Before the first build").
# monk/rackup/webrick are pure Ruby. The --postgres/--auth scaffold
# overrides this file to add libpq for the pg gem's native extension.
FROM ruby:4.0-slim AS builder
WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install

FROM ruby:4.0-slim
WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

# Matches bin/server's own default (PORT overrides both, e.g. on a
# platform that assigns its own). bin/websocket_server (WS_PORT default
# 9293) is a separate process/deploy unit -- run this same image with
# `bin/websocket_server` as the command instead of publishing another
# port from this Dockerfile -- see docs/guides/deploying.md.
EXPOSE 9292
CMD ["bin/server", "--bind", "0.0.0.0"]
