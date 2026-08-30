FROM ruby:4.0-slim AS builder

WORKDIR /app

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends git build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile monk.gemspec LICENSE.txt README.md ./
COPY lib lib

RUN bundle install

FROM ruby:4.0-slim

WORKDIR /app

# git is required at runtime too: monk.gemspec shells out to `git ls-files`,
# and Bundler re-evaluates the gemspec on every `bundle exec`.
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY . .

EXPOSE 9293

CMD ["bin/server", "--bind", "0.0.0.0"]
