# Development dependencies (the gemspec's add_development_dependency lines:
# test tools, linters, optional backends) stay out of the image. Set in both
# stages: the builder installs without them, and the final stage's
# `bundle exec` must not go looking for them either.
FROM ruby:4.0-slim AS builder

ENV BUNDLE_WITHOUT=development

WORKDIR /app

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends git build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile monk.gemspec LICENSE.txt README.md ./
COPY lib lib

RUN bundle install

FROM ruby:4.0-slim

ENV BUNDLE_WITHOUT=development

WORKDIR /app

# git is required at runtime too: monk.gemspec shells out to `git ls-files`,
# and Bundler re-evaluates the gemspec on every `bundle exec`.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bundle /usr/local/bundle
# The lockfile the builder resolved (.dockerignore keeps the host's out).
# Without it `bundle exec` re-resolves every group at startup, including the
# development gems this image deliberately doesn't have.
COPY --from=builder /app/Gemfile.lock ./Gemfile.lock
COPY . .

EXPOSE 9293

CMD ["bin/server", "--bind", "0.0.0.0"]
