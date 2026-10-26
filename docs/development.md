# Working on this repo

This is the framework's own source checkout — `config.ru` at the repo root
is a demo app exercising most of the features in this documentation, not a project
scaffolded with `monk new`. To run its test suite and its demo server:

```
bundle install
bundle exec rake test          # Minitest, calling App.call(env) directly
                                # against hand-built Rack env hashes -- see
                                # test/test_helper.rb; no Rack::Test dependency
bin/server                     # serves config.ru via kino, default (ractor) mode
bin/server --mode threaded     # threaded mode, useful as a stopgap if something isn't booting cleanly
bin/server --check             # reports Ractor-shareability without serving
PORT=9999 bin/server           # change the port (default 9293)
```

## Services the test suite needs

The suite runs with 0 skips only when three services are up. Start them
once with Docker; each test reads its URL from a `MONK_TEST_*` variable
with the default shown.

```
# Postgres with TLS on, for the probe over TLS in persistence_test.rb
docker run -d --name monk-test-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=monk_test \
  postgres:16.15 -c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem \
  -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key

# Redis, for the WebSocket and Live fan-out tests
docker run -d --name monk-test-redis -p 6379:6379 redis:7.4.11

# floci, an S3-compatible server, for the S3 storage backend's tests.
# FLOCI_AUTH_VALIDATE_SIGNATURES is required: without it floci accepts any
# signature, and the tests stop with a message saying so.
docker run -d --name monk-floci -p 4566:4566 -e FLOCI_AUTH_VALIDATE_SIGNATURES=true floci/floci:2.3.0
```

| Service | Variables | Default |
|---|---|---|
| Postgres | `MONK_TEST_PG_HOST`, `_PORT`, `_USER`, `_PASSWORD`, `_DATABASE` | `127.0.0.1`, `5432`, `postgres`, `postgres`, `monk_test` |
| Redis | `MONK_TEST_REDIS_URL` | `redis://127.0.0.1:6379/0` |
| S3 | `MONK_TEST_STORAGE_URL` | `s3://test:test@monk-test?endpoint=http://127.0.0.1:4566&region=us-east-1&path_style=1` |

The Postgres and Redis tests skip when their service is missing; the S3
tests fail instead, naming the command above. The S3 tests create the
`monk-test` bucket and empty it before each test.

## Running in Docker

```
docker build -t monk .
docker run --rm -p 9293:9293 monk
```

This serves `config.ru` via `bin/server`, bound to `0.0.0.0` so it's reachable from outside the container (kino's own default, `127.0.0.1`, wouldn't be). Change the published port with `-p <host-port>:9293`, e.g. `docker run --rm -p 9999:9293 monk`.
