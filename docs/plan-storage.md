# File storage (`Monk::Storage`): implementation plan

Status: draft 2026-10-07. Phases 1 to 4 done 2026-10-23.
Companion record: [`adr/0018-storage-s3-compatible-direct-upload.md`](adr/0018-storage-s3-compatible-direct-upload.md)
(why S3 is the only remote backend, why uploads skip the app, why
downloads redirect, and the four Hetzner open items).

`Monk::Storage` is a new opt-in module (`require "monk/storage"`), built
like `Monk::Mail`: the URL is parsed by `configure`, sealed by a freeze
hook, and each backend is a frozen `Data` value whose client is built
for each call. `Base#dispatch` gains one line for the file backend's
routes. Apart from that and the scaffold, nothing outside
`lib/monk/storage*` changes. Each step is a small red → green slice, as
in the earlier plans.

## Target layout

```
lib/monk/storage.rb                 # configure, the API (delegates to the backend), freeze_registry!, response(env)
lib/monk/storage/errors.rb
lib/monk/storage/url.rb             # STORAGE_URL -> backend value, redacted errors (like Mail::URL)
lib/monk/storage/key.rb             # generate / validate!
lib/monk/storage/input.rb           # content type, body and range checks both backends share
lib/monk/storage/object.rb          # Data: key, byte_size, content_type, etag (head's result)
lib/monk/storage/upload.rb          # Data: url, headers (presigned_put's result)
lib/monk/storage/sniff.rb           # magic bytes -> content type; SVG refusal
lib/monk/storage/backends/file.rb   # Data: root, secret
lib/monk/storage/backends/s3.rb     # Data: bucket, endpoint, region, access_key, secret_key, path_style, tls
lib/monk/storage/sig_v4.rb          # header signing + query presigning, pure functions
lib/monk/storage/token.rb           # file backend's HMAC tokens for /_monk/storage/:token
lib/monk/storage/routes.rb          # PUT/GET /_monk/storage/:token, called by Storage.response(env)
lib/monk/generators/storage.rb      # monk add storage
lib/monk/templates/storage/...
docs/guides/storage.md
test/storage_*_test.rb
```

## Decisions

These fill gaps the ADR leaves open. Each can still change in review.

1. **`Monk::Storage.configure(url:, secret: nil)`** in
   `config/storage.rb`, called as
   `configure(url: ENV["STORAGE_URL"], secret: ENV["STORAGE_SECRET"])`.
   An unset or empty `url` gives `file://storage/<env>` in development and
   test, and raises `MissingStorageUrlError` in staging and production
   (ADR table). `secret` is used only by the file backend. In development
   and test it defaults to a fixed constant, and in staging and production
   leaving it out with `file://` raises `MissingStorageSecretError`.
2. **The module-level API delegates to the configured backend.** Both
   backends implement `put`, `get`, `head`, `delete`, `copy`, `url` and
   `presigned_put` with the same signatures, and one shared contract test
   runs against each. `generate_key` lives on the module, since it doesn't
   depend on the backend.
3. **Return values.** `put` returns the key. `get` returns a binary,
   frozen `String` (a `get_to(key, io)` for large files waits until an app
   needs it). `head` returns a `Storage::Object`, or `nil` when the key
   is missing. `delete` is idempotent, like S3. `copy(from, to)` returns
   `to`. `url` returns a `String`. `presigned_put` returns
   `Upload(url:, headers:)`, where `headers` lists exactly what the browser
   must send (`Content-Type`, and `Content-Length` for clarity, since
   browsers set it themselves). A missing key raises
   `Storage::NotFoundError` from `get` and `copy`. Any other failure raises
   `Storage::RequestError`, with the original error as its `#cause`, the
   way `Mail::DeliveryError` works.
4. **Keys.** `generate_key(prefix:)` returns
   `"#{prefix}/#{SecureRandom.hex(16)}"`, 128 random bits. Keys are lowercase
   only, because macOS disks are case-insensitive and the file backend
   must not merge two keys that a bucket keeps apart. `Key.validate!`
   runs on every call to either backend and accepts
   `\A[a-z0-9][a-z0-9._\-]*(/[a-z0-9][a-z0-9._\-]*)*\z`, at most 512 bytes:
   no `..` segment, no empty segment, no leading `/`. The file backend
   also runs the `Assets#disk_entry` containment check after resolving
   the path.
5. **`tmp/` is the app's convention, written by the app, and Monk adds no
   `promote`/`move` helper.** Confirming an upload is `head`, sniff, the
   app's checks, `copy`, `delete` and the record, all in the app's route.
   A helper could only cover `copy` + `delete`, which saves one line. A
   forgotten `delete` costs a day of storage because the lifecycle rule
   expires `tmp/`. The name would suggest an atomic rename that S3 doesn't
   have. It doesn't help when confirm is retried, and it has no meaning
   under the fallback for open item 4 (no copy at all). The guide and the
   scaffold's example route show the full confirm, with a comment on why
   the copy comes before the delete. A helper can be added later without
   breaking anything, if apps keep writing the same lines.
6. **The file backend stores metadata next to the bytes.** Objects go in
   `<root>/objects/<key>~` and metadata (content type, size, MD5 for
   `etag`) in `<root>/meta/<key>~.json`. The `~`, which no key contains,
   keeps a key's file apart from the directory of a longer key: a bucket
   has both `a` and `a/b`, and on disk `a` would otherwise be a file
   where `a/b` needs a directory. An object exists once its metadata
   does, so a put that died between the two renames isn't one. Writes go to a temporary file
   followed by `File.rename`, so a reader never sees half an object.
   `root` is expanded to an absolute path in `configure`, so worker
   Ractors don't depend on the current directory.
7. **The file backend's routes are served whenever the backend is
   `file://`, in any environment.** The ADR's table allows `file://` on a
   server volume and requires `STORAGE_SECRET` there, and its signed links
   only work if the routes exist. This is for a single-host deployment
   without a bucket. The guide states the costs: one host only (web and
   `bin/jobs` share the volume), and each upload and download holds a
   worker Ractor. `STORAGE_SECRET` is its own variable, separate from the
   auth secret, so rotating one doesn't invalidate the other's links, and
   storage doesn't depend on auth. `Monk::Storage.response(env)` is called
   in `Base#dispatch` right after `Monk::Assets.response(env)`. It returns
   `nil` unless the backend is `file://` and the path starts with
   `/_monk/storage/`, and it does nothing at all unless `monk/storage` is
   loaded (a `defined?` check, leaving `Base` without a hard dependency).
   ADR 0018 was amended to match on 2026-10-07.
8. **Tokens for the file backend** are
   `base64url(JSON payload) + "." + base64url(HMAC-SHA256)`, with the
   payload `{m: "GET"|"PUT", k: key, e: expires_at, l: length, t: type}`.
   Each check fails the way S3 fails: a bad signature or an expired token
   gives 403, a `PUT` whose `Content-Length` or `Content-Type` doesn't match
   the token gives 403, a body that doesn't match its declared length
   gives 400, and a missing object gives 404. Every response carries
   `X-Content-Type-Options: nosniff`, and `GET` serves the stored content
   type with `Cache-Control: private, max-age=<seconds until expiry>`.
9. **`cache_window` signing.** `t0 = now - (now % cache_window)`. S3 signs
   with `X-Amz-Date = t0` and `X-Amz-Expires = cache_window + expires_in`,
   so every link is valid for at least `expires_in`, and every call within
   one window returns the same URL. (The first draft had `X-Amz-Expires =
   (now - t0) + expires_in`, which expires at `now + expires_in` and so
   changes every second.) The file backend puts the same `expires_at`,
   `t0 + cache_window + expires_in`, in its token. Defaults:
   `cache_window: 3600`, `expires_in: 3600`, set in `configure`, which
   like `url` raises if `cache_window + expires_in` is over SigV4's 7-day
   limit. `presigned_put` has no window (each upload is its own link) and
   defaults to `expires_in: 600`.
10. **SigV4 is pure and tested against AWS's published vectors** (the
    `get-vanilla`, `post-x-www-form-urlencoded` and presigned-URL examples
    from the AWS SigV4 test suite and the S3 docs). It takes `now:` as an
    argument, so tests never stub `Time`.
11. **Sending a body.** `put` accepts a `String` or an IO that responds to
    `size`, `read` and `rewind` (`File`, `Tempfile`, `StringIO`). A pipe
    must first be written to a `Tempfile` by the app. For S3 the body's
    SHA-256 is computed first and signed as `x-amz-content-sha256`, then
    the IO is rewound and streamed with `body_stream`. That reads the body
    twice but never holds it in memory. Every S3-compatible service
    accepts this, since it is every SDK's default, and the server refuses
    a body that doesn't match the hash, which checks the bytes end to end.
    `UNSIGNED-PAYLOAD` and chunked signing aren't used. Unsigned could be
    added as an option if hashing ever shows up in profiles (multi-GB
    files from jobs).
12. **`get(key, range: nil)` and `Sniff`.** `range:` is a Ruby `Range` of
    byte offsets: a `Range:` header on S3, a slice of the file on disk.
    A range that ends past the object gives what's there, and one that
    starts past it gives `""` (S3 answers 416, which the S3 backend maps
    to `""`), so a confirm route can read the first 16 bytes of any
    upload, even an empty one. `head`'s `etag` is the MD5 in hex without
    the quotes S3 puts around it.
    `Sniff.content_type(bytes)` reads the first 16 bytes and returns one of
    `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `audio/ogg` (an
    `OggS` page with an `OpusHead`), `application/pdf`, or `nil`.
    `Sniff.refuse_svg!(bytes)` raises `UnsafeContentError` if it finds `<svg`
    or `<?xml` near the start. At confirm the app reads those bytes with
    `get(key, range: 0..15)`, so the whole file is never downloaded. The
    type check is defence in depth: the served `Content-Type` is the one
    the app signed into `presigned_put` from its allowed list. The check
    catches mislabelled plain files. Apps that encrypt in the browser
    (monk_talk) store ciphertext as `application/octet-stream` and skip it.
    Separately, the file backend's `GET /_monk/storage/:token` answers
    `Range` with `206` and `Content-Range`, as a bucket does, because Safari
    won't play `<audio>`/`<video>` without it. ADR 0018 was amended to
    match on 2026-10-07.
13. **Logging.** Each backend call writes one `Monk::Log.info` line
    (`[storage] put key=… bytes=… 23ms`). URLs, signatures and tokens are
    never logged, and `inspect` on a backend redacts its secrets, as
    `Transports::SMTP` does.

## Phases

### Phase 1: configure, URL parsing, freeze hook

- `errors.rb`: `NotConfiguredError`, `InvalidStorageUrlError`,
  `MissingStorageUrlError`, `MissingStorageSecretError`, `InvalidKeyError`,
  `NotFoundError`, `RequestError`, `UnsafeContentError`.
- `url.rb`: `file://<dir>` (relative or absolute) and
  `s3://KEY:SECRET@bucket?endpoint=…&region=…[&path_style=1]`. It requires
  `endpoint` and `region`, rejects unknown options, URL-decodes the
  credentials, and redacts the secret in errors (copied from
  `Mail::URL.redact`). A bare `endpoint` host means HTTPS. An
  `http://` prefix is accepted for a local server only (MinIO in the
  test suite) and refused in staging and production.
- `storage.rb`: `configure`, `config`, `freeze_registry!`, `reset!`, and
  registration with `Monk.freeze_hooks`.
- Tests (`storage_config_test.rb`): each row of the ADR table, each
  invalid URL, the secret rules by environment, the redaction, and a
  config that can be read from a worker Ractor after `Monk.freeze!`.

### Phase 2: keys and the file backend's operations

- `key.rb`: `generate`, `validate!` (decision 4).
- `backends/file.rb`: `put`, `get` (with `range:`), `head`, `delete`,
  `copy` (decision 6).
- `test/support/storage_contract.rb`: one shared module of contract tests
  (round trip, `head` on a missing key, idempotent `delete`, `copy` then
  `delete` the source, content type kept, binary-safe bytes, an IO body,
  a ranged get). Phase 5 runs it against S3.
- Tests: traversal attempts (`../`, encoded forms, `\0`, symlinks inside
  the root that point outside it), uppercase keys refused, every
  operation called from a worker Ractor.

### Phase 3: file backend signed URLs and `/_monk/storage` routes

- `token.rb` (decision 8), then `url` and `presigned_put` on the file
  backend (decision 9). Both return relative paths
  `/_monk/storage/<token>`.
- `Monk::Storage.response(env)` and the one-line hook in `Base#dispatch`
  (decision 7). The `PUT` handler streams `rack.input` into the backend in
  chunks and counts bytes, without `parse_json_body`.
- Tests: the full browser flow through `Monk.boot(App)` and `Rack::MockRequest`
  (presign, PUT, head, copy out of `tmp/`, delete, `url`, GET), each 403
  and 400 case from decision 8, a `Range` GET answered with `206`,
  `nosniff`, the same URL within one
  `cache_window`, a token signed with the development secret accepted by
  a second process configured the same way (the `bin/jobs` case), and no
  route without `monk/storage` or with an S3 backend.

### Phase 4: SigV4

- `sig_v4.rb`: canonical request, string to sign, signing key, the
  `Authorization` header, and query presigning. Paths and query strings
  are encoded the S3 way: `/` is kept in keys, everything else follows
  RFC 3986.
- Tests: the AWS vectors (decision 10), and signing from a worker
  Ractor (`OpenSSL::HMAC` inside a Ractor, as the spike measured).

### Phase 5: the S3 backend

- `backends/s3.rb`: one `Net::HTTP` per call, built in the calling Ractor,
  with `open_timeout`/`read_timeout` as in `Transports::SMTP`. Uses
  virtual-hosted URLs by default and path-style with `path_style=1`.
  `copy` sends `x-amz-copy-source` and checks the response body for an
  `<Error>`, since S3 can answer 200 to a failed copy. `head` maps a 404
  to `nil`. Ranged `get` sends `Range:`.
- `url` and `presigned_put` (decision 9), with `Content-Type` and
  `Content-Length` among the signed headers of the presigned PUT.
- Tests: request shape against a local `WEBrick`-free fake (a
  `TCPServer` in a thread that records the request), checked with the
  Phase 4 signer. Plus `storage_s3_integration_test.rb`, the ADR's spike
  rebuilt as a test: it runs the contract tests and the browser flow
  (presigned PUT with `Net::HTTP` acting as the browser, wrong length and
  wrong type refused, ranged get, copy, signed GET) from a worker Ractor
  against a local MinIO container, never skipped, like the Postgres and
  Redis tests. A `StorageTestHelpers` module in `test_helper.rb` reads
  `MONK_TEST_STORAGE_URL`, defaulting to
  `s3://minioadmin:minioadmin@monk-test?endpoint=http://127.0.0.1:9000&region=us-east-1&path_style=1`,
  and creates the bucket if it's missing (one signed `PUT /monk-test`).
  If MinIO can't be reached, the test fails with the command that starts
  it: `docker run -d --name monk-minio -p 9000:9000 minio/minio server /data`,
  written down in `docs/development.md`'s test section. MinIO checks signatures strictly, including the signed
  `Content-Length` and `Content-Type`.

### Phase 6: content sniffing

- `sniff.rb` (decision 12), with a small fixture of first bytes per type,
  plus SVG and HTML samples.

### Phase 7: verifying the four open items on Hetzner (manual, before the S3 backend ships)

Run by you on a staging Hetzner project: `MONK_TEST_STORAGE_URL=s3://…fsn1…`
and the Phase 5 integration test, plus one script per item:

1. A presigned PUT with a longer body, then with another content type:
   both refused.
2. Apply the guide's CORS XML, then send a browser-like preflight from
   the app's origin (allowed) and from another origin (refused).
3. Apply the guide's lifecycle XML using `<Filter><Prefix>`, and fall back
   to the top-level `<Prefix>`. Write down which one is accepted.
4. `copy` with region `fsn1`, once virtual-hosted and once path-style.

The results go into the ADR's Open items, and the guide uses only what
passed. A failure moves to the fallback the ADR names for that item, and
this plan gets a new phase for it.

### Phase 8: `monk add storage`

A generator of its own (`lib/monk/generators/storage.rb`), built like
`mail`'s under ADR 0017: it only creates files and appends lines. What
it writes is what was settled on 2026-10-07: config and the upload
flow, with no migration and no JS. The flow comes as commented examples, not
as live routes, because ADR 0017 gives only `live` a demo, and a live
`/media` route would have no access check.

- `installed_if "config/storage.rb"`, no `depends_on`: the file backend
  needs no service.
- `templates/storage/config/storage.rb` (`role: :wiring`):
  `require "monk/storage"` and `configure` (decision 1). The static
  `config/load.rb` already requires it, after `live`.
- No `.env` / `.env.test` lines: an unset `STORAGE_URL` already gives
  `file://storage/<env>` (decision 1), so tests never touch
  development's files. `env :example, commented: true`: an S3
  `STORAGE_URL`, and `STORAGE_SECRET` for `file://` on a server.
  `ignore "/storage/"` goes in `.gitignore` and `.dockerignore`.
- `templates/storage/app/routes/storage.rb` (`role: :example`), reopening
  `class App`, with the flow as commented blocks that can be driven with
  `curl`, without any JavaScript:
  - `# monk:example storage-upload`: `POST /uploads` (`presigned_put` on
    `tmp/`), then the `curl -X PUT` in a comment;
  - `# monk:example storage-confirm`: `POST /uploads/confirm` (head,
    sniff, copy, then delete, in the order from decision 5);
  - `# monk:example storage-download`: `GET /media/*key` (302 to `url`),
    with a comment that it has no access check and must become a record
    lookup in a real app.
- `templates/storage/test/storage_test.rb` (`role: :test`): the wiring
  proved against the file backend: a `put`, `head` and `get` of a key,
  and a signed link that answers 200.
- `setup_section "storage/setup.md"` (the file backend in development,
  pointing at the guide for a bucket) and `agents_section
  "storage/agents.md"` (Where, Main calls, Test, Pitfalls, Examples: keys
  under `tmp/` until confirmed, copy before delete, no multipart in a
  worker Ractor).
- `set_before_production "STORAGE_URL"` (an S3 bucket; `file://` only on
  one server with a volume) and `"STORAGE_SECRET"` (only with `file://`:
  signs its links).
- No `service`: development and tests use `file://`. Checking a real
  bucket (access, CORS for `PUBLIC_URL`) is the environment check's job
  on the roadmap, not the generator's.
- No migration and no JS. The guide carries them as examples to copy: an
  `attachments` SQL table (`.up.sql`/`.down.sql`), upload JS with
  `fetch`, and a `/media/:id` route with an access check. They depend on
  the app, and an app that encrypts in the browser would differ anyway.
- Tests: `test/generators/storage_test.rb` (the files, env lines, ignore
  lines, running it twice is a no-op, `--json` output), the three examples
  added to `examples_test.rb` (uncommented, booted, and the full upload →
  confirm → download flow run against the file backend), and `storage`
  added to `combinations_test.rb`.

### Phase 9: docs

- `docs/guides/storage.md`: configuration, the API, the upload and
  download flows with code, the file backend in development and tests,
  a section per provider (Hetzner, R2, B2, AWS, MinIO: endpoint, region,
  addressing style), the CORS and lifecycle XML from Phase 7, and the two
  Hetzner facts (one project per environment, backups as
  download-and-upload jobs).
- `CONTEXT.md`: Storage, key, `tmp/` upload, confirm, signed link,
  cache window.
- `docs/development.md`: a test section listing the three containers the
  suite needs, so it runs with 0 skips: Postgres with `ssl = on` (for the
  probe over TLS in `persistence_test.rb`), Redis, and MinIO (Phase 5).
  For each, the `docker run` command, the `MONK_TEST_*` variables
  `test_helper.rb` reads and their defaults. The skip messages in
  `test_helper.rb` point there instead of
  `docs/design/persistence-ractor-connections.md`.
- README module list, CHANGELOG entry. The version bump is left to you.
- When everything is done, this plan moves to `docs/history/`.

## Open questions for review

None left. A, B, C, D and E were settled on 2026-10-07 and are recorded
in decisions 5, 7, 11, 12 and Phase 8.
