# Same shape as the base Dockerfile, plus libpq: the pg gem's native
# extension needs libpq-dev (headers) to compile in the builder stage and
# libpq5 (the runtime lib alone, no headers) in the final image.
FROM ruby:4.0-slim AS builder
WORKDIR /app

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock* ./
RUN bundle install

FROM ruby:4.0-slim
WORKDIR /app

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

# Matches bin/server's own default (PORT overrides both, e.g. on a
# platform that assigns its own). bin/websocket_server (WS_PORT default
# 9293) is a separate process/deploy unit -- run this same image with
# `bin/websocket_server` as the command instead of publishing another
# port from this Dockerfile -- see docs/guides/deploying.md.
EXPOSE 9292
CMD ["bin/server", "--bind", "0.0.0.0"]
