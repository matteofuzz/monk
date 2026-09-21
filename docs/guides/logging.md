# Request logging — `Monk::Log`

Every request is appended as one line to `log/<env>.log` —
`log/development.log`, `log/test.log`, `log/production.log`, `log/staging.log`,
Rails-style — unconditionally, in every environment:

```
2026-09-17T14:32:01.123Z GET /hello -> 200 (1.2ms)
```

In development that same line is also echoed to `$stdout`, for a human
tailing the console; the file write happens either way. Each worker Ractor
lazily opens and keeps its own append-mode handle to the log file (a `File`
isn't `Ractor`-shareable the way `$stdout` is, so there's no single handle
every worker can share), and concurrent `O_APPEND` writers to the same path
need no extra locking — the same guarantee already relied on for several
worker Ractors sharing `$stdout`. `Monk::Log.root = "log"` is the only
knob; there's no per-route opt-out.

For app-level logging (not the per-request access line above),
`Monk::Log.debug`/`.info`/`.warn`/`.error` each write one
`TIMESTAMP LEVEL message` line to the same `log/<env>.log`, gated by the
`log_level` setting (`debug`/`info`/`warn`/`error`, `info` by default) — a
call below the configured threshold is a no-op, cheap enough to leave
`Log.debug` calls in place rather than stripping them per environment:

```ruby
Monk::Log.debug("cache miss for #{key}")  # only written when log_level is "debug"
Monk::Log.warn("payment retried")
```

```
2026-09-17T14:32:01.456Z WARN payment retried
```

Both lines share the same timestamp format: UTC, millisecond precision,
ISO 8601 (`Monk::Log.timestamp`) — sortable as plain text and unambiguous
across machines/timezones.

`log_level` is implicit like `MONK_ENV` — no `configure` call needed, just
set `LOG_LEVEL` in the environment. It's validated at `Monk.boot` the same
way any declared setting is, and resolved once into `Log`'s threshold
rather than re-read per call.
