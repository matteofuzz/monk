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

## Running in Docker

```
docker build -t monk .
docker run --rm -p 9293:9293 monk
```

This serves `config.ru` via `bin/server`, bound to `0.0.0.0` so it's reachable from outside the container (kino's own default, `127.0.0.1`, wouldn't be). Change the published port with `-p <host-port>:9293`, e.g. `docker run --rm -p 9999:9293 monk`.
