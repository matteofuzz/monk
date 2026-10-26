# Two-stage build: the builder resolves and installs gems, the final image
# only keeps the installed bundle plus the app -- no compiler, no gem
# cache, in the image that actually runs. The builder has a compiler for
# the gems that build a native extension (irb's dependencies, with monk
# add postgres); kino ships as precompiled platform gems, and pg 1.6+
# ships precompiled with its own libpq. A plain `bundle install`
# (Gemfile.lock committed) already resolves every compatible platform, not
# just the machine that ran it -- nothing to add by hand before building on
# a different host (docs/guides/deploying.md, "Before the first build").
FROM ruby:4.0-slim AS builder
WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

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
# port from this Dockerfile -- see docs/guides/deploying.md. Every other
# process in bin/ (bin/jobs, say) is the same: this image, that command.
# Production unless the platform says otherwise (MONK_ENV=staging in its
# env, say). Unset, Monk runs as development: mail printed instead of
# sent, magic links logged, demo routes on, a public storage secret.
ENV MONK_ENV=production

EXPOSE 9292
CMD ["bin/server", "--bind", "0.0.0.0"]
