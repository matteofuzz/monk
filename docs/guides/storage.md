# Storing files — `Monk::Storage`

The files users send (photos, voice notes, documents), stored by key in
any S3-compatible bucket, and on the local disk in development and test.
Opt-in: `require "monk"` never loads it. Uploads go from the browser
straight to the bucket through a signed link, and downloads redirect to
one, so the bytes never pass through a worker Ractor
(`docs/adr/0018-storage-s3-compatible-direct-upload.md`). Deliberately
small: Monk stores bytes and the app keeps the records. No attachments
table, no image processing, no multipart uploads to S3.

```ruby
# config/storage.rb -- `monk add storage` writes this (as Settings) for you
require "monk/storage"

Monk::Storage.configure(url: ENV["STORAGE_URL"], secret: ENV["STORAGE_SECRET"])
```

```ruby
key = Monk::Storage.generate_key(prefix: "reports")
Monk::Storage.put(key, File.open("report.pdf"), content_type: "application/pdf")
Monk::Storage.get(key)    # => the bytes
Monk::Storage.url(key)    # => a signed link to redirect to
```

## `STORAGE_URL`

One URL picks the backend. It's parsed by `configure`, so a malformed one
fails the boot, not the first upload.

| `STORAGE_URL` | Backend |
|---|---|
| unset or empty, in development or test | `file://storage/<env>`: files under the app's `storage/development` or `storage/test` |
| `file:///var/lib/app/storage` | the local disk, anywhere (an absolute path, or one relative to the app) |
| `s3://KEY:SECRET@bucket?endpoint=host&region=name` | any S3-compatible bucket, the bucket in the host name (`bucket.host`) |
| `s3://…&path_style=1` | the same, the bucket in the path (`host/bucket`), for local servers and providers that want it |
| unset or empty, in staging or production | `Monk::Storage::MissingStorageUrlError` at boot: on a host whose disk is replaced on deploy, local files would lose every upload |

`endpoint=` is a host, optionally with a port, and means HTTPS. An
`http://` endpoint sends the keys and every body in clear, so it's
accepted only for a local server (MinIO, floci), never in staging or
production. Percent-encode a key containing `/`, `+`, `@` or `:`
(`%2F`, `%2B`, `%40`, `%3A`). The secret key is never shown in error
messages or in the backend's `inspect`.

`STORAGE_SECRET` signs the file backend's links, and is only read with a
`file://` URL. In development and test it defaults to a fixed value, so a
link built by `bin/jobs` also works in `bin/server`. Anywhere else,
`file://` without it raises `Monk::Storage::MissingStorageSecretError` at
boot. Give it a random value of its own, not the auth secret, so rotating
one doesn't invalidate the other's links:

```sh
ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'
```

`configure` also takes the defaults for download links, `expires_in:`
(3600) and `cache_window:` (3600), in seconds: see "Downloads".

## Keys

A key names one object: segments of `a-z`, `0-9`, `.`, `_` and `-`,
each starting with a letter or digit, joined by `/`, at most 512 bytes.
Lowercase only, so the file backend on a case-insensitive disk (macOS)
never merges two keys a bucket keeps apart. Every call checks its key and
raises `Monk::Storage::InvalidKeyError` (an `ArgumentError`) on any
other.

Make every new key with `generate_key`, which puts 128 random bits under a
prefix:

```ruby
Monk::Storage.generate_key(prefix: "tmp")   # => "tmp/1f0c9e…" (32 hex digits)
```

Never build a key from a user's filename: that's how path traversal and
file names in URLs happen. Keep the filename in your own table. A key
isn't the content's hash either: a hash would show that two users stored
the same file, and deleting one would need reference counting.

## The API

The same calls on every backend, each logged as one line
(`[storage] put key=reports/1f0c… bytes=48213 23ms`) without URLs,
signatures or tokens.

| Call | Returns |
|---|---|
| `put(key, body, content_type: "application/octet-stream")` | the key. `body` is a `String` or an IO that responds to `size`, `read` and `rewind` (`File`, `Tempfile`, `StringIO`); write a pipe to a `Tempfile` first |
| `get(key, range: nil)` | the bytes, a frozen binary `String`. `range:` is a Ruby `Range` of byte offsets: `0..63` reads the first 64. A range past the end gives what's there, or `""` |
| `head(key)` | a `Monk::Storage::Object` (`key`, `byte_size`, `content_type`, `etag`: the MD5 in hex), or `nil` when the key is missing |
| `delete(key)` | `nil`. Deleting a missing key isn't an error |
| `copy(from, to)` | `to`. Within one bucket only |
| `url(key, expires_in:, cache_window:)` | a signed download link, a `String` |
| `presigned_put(key, content_type:, byte_size:, expires_in: 600)` | a `Monk::Storage::Upload`: the `url` to PUT the file to and the `headers` to send with it |
| `generate_key(prefix:)` | a new random key under `prefix` |

`get` and `copy` raise `Monk::Storage::NotFoundError` for a missing key.
Anything else that fails on the way to or from the bucket (the network,
TLS, the disk, the bucket refusing the request) raises
`Monk::Storage::RequestError`, with the original exception as its
`#cause`. Calling any of them before `configure` raises
`Monk::Storage::NotConfiguredError`.

Every call works from any worker Ractor, after boot: the backend is a
frozen value, and each call opens its own connection.

On S3, `put` reads the body twice: once to sign its SHA-256, once to
send it. The body is never held in memory, and the bucket refuses bytes
that don't match the hash. A single `put` takes up to 5 GB on AWS and on
Hetzner.

## Uploads from the browser

A browser uploads straight to the bucket, through a link the app signs,
so no worker Ractor waits while the bytes travel. The flow has three
steps, and two of them are the app's own routes:

1. **The app signs a link.** A route checks the session, the type and
   the size, then answers a `presigned_put` link for a key under `tmp/`,
   valid for 10 minutes. `Content-Type` and `Content-Length` are inside
   the signature: the bucket refuses another type or length with 403,
   and stores nothing.
2. **The browser PUTs the file** to that link.
3. **The app confirms it.** The browser calls a second route, which
   checks what arrived, copies it out of `tmp/`, deletes the `tmp/` copy
   and records it. Nothing else tells the app an upload happened (Hetzner
   has no event notifications), so this call is the only signal. An
   upload that's never confirmed is deleted by the bucket's lifecycle
   rule after a day, with no cleanup job (see "Setting up a bucket").

`monk add storage` writes the two routes as the commented
`storage-upload` and `storage-confirm` examples in
`app/routes/storage.rb`. Here they are with a session, for an app with
`monk add auth`:

```ruby
class App
  post("/uploads") do
    require_user!
    require_csrf!
    content_type = params[:content_type].to_s
    byte_size = params[:byte_size].to_i
    halt 422, "type not accepted" unless %w[image/png image/jpeg image/webp application/pdf].include?(content_type)
    halt 422, "size not accepted" unless byte_size.between?(1, 10 * 1024 * 1024)

    key = Monk::Storage.generate_key(prefix: "tmp")
    upload = Monk::Storage.presigned_put(key, content_type: content_type, byte_size: byte_size)
    json(key: key, url: upload.url, headers: upload.headers)
  end

  post("/uploads/confirm") do
    owner = require_user!
    require_csrf!
    key = params[:key].to_s
    halt 422, "not an upload" unless key.match?(%r{\Atmp/[0-9a-f]{32}\z})
    object = Monk::Storage.head(key)
    halt 404, "no such upload" unless object

    first_bytes = Monk::Storage.get(key, range: Monk::Storage::Sniff::RANGE)
    unless Monk::Storage::Sniff.content_type(first_bytes) == object.content_type
      Monk::Storage.delete(key)
      halt 422, "the file isn't a #{object.content_type}"
    end

    media_key = key.sub("tmp/", "media/")
    Monk::Storage.copy(key, media_key)
    Monk::Storage.delete(key)
    id = Monk::Persistence::Pg.checkout(:primary) do |conn|
      conn.exec_params(<<~SQL, [owner, media_key, params[:filename].to_s, object.content_type,
                                object.byte_size, object.etag,]).first["id"]
        INSERT INTO attachments (owner, key, filename, content_type, byte_size, checksum)
        VALUES ($1, $2, $3, $4, $5, $6) RETURNING id
      SQL
    end
    json(id: id)
  end
end
```

**Copy first, then delete.** If the copy fails, the `tmp/` file is
still there, and the lifecycle rule expires it. Deleting first would
lose the upload. S3 has no rename, so Monk doesn't pretend to have one:
there's no `move` helper.

**Anyone could have uploaded to `tmp/`**, with any link the app signed.
The confirm route is where the app decides: check who asked for the
link if it matters (store the key with the user when signing, and look
it up here), and check the bytes.

### What the bytes say: `Sniff`

The type a client sends can't be trusted, so the confirm route reads the
first 64 bytes, `get(key, range: Sniff::RANGE)`, never the whole file,
and checks them:

- `Sniff.content_type(bytes)` returns `"image/png"`, `"image/jpeg"`,
  `"image/gif"`, `"image/webp"`, `"audio/ogg"` (an Ogg stream of Opus
  audio), `"application/pdf"`, or `nil` for anything else.
- `Sniff.refuse_svg!(bytes)` raises `Monk::Storage::UnsafeContentError`
  when `<svg` or `<?xml` appears in those bytes. Use it if the app
  accepts types `Sniff` doesn't know; comparing with `content_type`, as
  above, already refuses SVG, since `Sniff` never names it.

This is defence in depth: the type a signed link serves is the one the
app signed into `presigned_put`, from its own allowed list. It catches a
plain file labelled as an image. **Never accept SVG or HTML uploads**:
both can carry scripts. An app that encrypts files in the browser stores
ciphertext as `application/octet-stream` and skips the check.

### The browser's side

The page asks for a link, PUTs the file, then confirms. The browser sets
`Content-Length` itself, from the file, and `fetch` sends the
`Content-Type` given:

```js
async function upload(file) {
  const csrf = { "x-csrf-token": document.cookie.match(/csrf_token=([^;]+)/)?.[1] }
  const json = { "content-type": "application/json", ...csrf }

  const signed = await fetch("/uploads", {
    method: "POST", headers: json,
    body: JSON.stringify({ content_type: file.type, byte_size: file.size }),
  })
  if (!signed.ok) throw new Error(await signed.text())
  const { key, url, headers } = await signed.json()

  const put = await fetch(url, { method: "PUT", headers: { "Content-Type": headers["Content-Type"] }, body: file })
  if (!put.ok) throw new Error(`upload refused: ${put.status}`)

  const confirmed = await fetch("/uploads/confirm", {
    method: "POST", headers: json, body: JSON.stringify({ key, filename: file.name }),
  })
  if (!confirmed.ok) throw new Error(await confirmed.text())
  return (await confirmed.json()).id
}
```

A PUT to a bucket on another origin needs the bucket's CORS rule. In
development the link is a path on the app itself (the file backend), so
no CORS is involved. There's no upload form without JavaScript: Monk
doesn't parse `multipart/form-data`, because Rack's parser can't run in a
worker Ractor.

## Downloads

Pages link to the app's own stable URL, never to a signed link. The
route checks that the viewer may see the file, then redirects (302) to
`url(key)`:

```ruby
class App
  get("/media/:id") do
    owner = require_user!
    key = Monk::Persistence::Pg.checkout(:primary) do |conn|
      conn.exec_params("SELECT key FROM attachments WHERE id = $1 AND owner = $2", [params[:id], owner])
          .first&.fetch("key")
    end
    halt 404, "" unless key

    redirect Monk::Storage.url(key)
  end
end
```

A signed link works for anyone who has it, until it expires: the route
is where access is checked, on every view. A Live patch is rendered once
for every subscriber, so it must never contain a signed link, which
expires and could belong to another viewer.

`url` rounds the signing time down to `cache_window` (an hour by
default) and signs for `expires_in` beyond it. Every redirect within the
hour points at the same URL, so the browser's cache works, and each link
is valid for at least `expires_in`. Together they stay within the 7
days a signed S3 link allows. Pass either to `url` to change one link,
or to `configure` to change the defaults.

The bucket stays private. A signed link serves the stored
`Content-Type`, and answers `Range` requests with 206, which `<audio>`
and `<video>` need (Safari won't play them otherwise).

The `storage-download` example in `app/routes/storage.rb` is
`GET /media/*` by key, with **no access check**: it shows the redirect,
and becomes a record lookup like the one above in a real app.

## An uploads table to copy

Monk keeps no record of a file. What an app records depends on the app,
so here's a starting point to adapt, as a migration
(`db/migrate/<timestamp>_create_attachments.up.sql`):

```sql
CREATE TABLE attachments (
  id BIGSERIAL PRIMARY KEY,
  owner TEXT NOT NULL,              -- whatever identifies the uploader (Monk::Auth's subject)
  key TEXT NOT NULL UNIQUE,         -- media/<hex>, from generate_key
  filename TEXT NOT NULL,           -- as the user named it: shown, never used as a key
  content_type TEXT NOT NULL,
  byte_size BIGINT NOT NULL,
  checksum TEXT NOT NULL,           -- head's etag, the MD5 in hex
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX attachments_owner ON attachments (owner);
```

and its `.down.sql`:

```sql
DROP TABLE attachments;
```

Deleting a file is two steps in the app: delete the row, then
`Monk::Storage.delete(key)`. Deleting in that order leaves at worst an
orphaned object, never a row pointing at nothing.

## Setting up a bucket

A bucket needs two rules before browsers can use it: CORS, so a page on
the app's origin may PUT to it, and a lifecycle rule, so unconfirmed
uploads in `tmp/` don't pile up. Both were checked on Hetzner on
2026-10-26.

**CORS** (`cors.xml`), with your `PUBLIC_URL` as the origin, exactly as
the browser shows it (`https://`, no trailing slash; one
`<AllowedOrigin>` per origin):

```xml
<CORSConfiguration>
  <CORSRule>
    <AllowedOrigin>https://app.example.com</AllowedOrigin>
    <AllowedMethod>PUT</AllowedMethod>
    <AllowedHeader>content-type</AllowedHeader>
    <ExposeHeader>ETag</ExposeHeader>
    <MaxAgeSeconds>3600</MaxAgeSeconds>
  </CORSRule>
</CORSConfiguration>
```

Only `PUT` is needed: downloads are redirects that `<img>`, `<audio>`
and links follow without CORS.

**Lifecycle** (`lifecycle.xml`): `tmp/` expires after a day, and so do
unfinished multipart uploads, should anything start one:

```xml
<LifecycleConfiguration>
  <Rule>
    <ID>expire-tmp</ID>
    <Filter><Prefix>tmp/</Prefix></Filter>
    <Status>Enabled</Status>
    <Expiration><Days>1</Days></Expiration>
    <AbortIncompleteMultipartUpload><DaysAfterInitiation>1</DaysAfterInitiation></AbortIncompleteMultipartUpload>
  </Rule>
</LifecycleConfiguration>
```

Hetzner also accepts the older form with `<Prefix>tmp/</Prefix>` in
place of `<Filter>`.

Apply both with any S3 tool. With [s3cmd](https://s3tools.org/s3cmd)
and Hetzner in `fsn1`:

```sh
s3cmd --host=fsn1.your-objectstorage.com --host-bucket='%(bucket)s.fsn1.your-objectstorage.com' \
  setcors cors.xml s3://my-bucket
s3cmd --host=fsn1.your-objectstorage.com --host-bucket='%(bucket)s.fsn1.your-objectstorage.com' \
  setlifecycle lifecycle.xml s3://my-bucket
```

(s3cmd asks for the access key and secret on first use, with
`s3cmd --configure`, or takes `--access_key` and `--secret_key`.)

To check a bucket the way Monk checked Hetzner's, run
`bin/storage_check` from a checkout of the monk repository, with
`STORAGE_CHECK_URL` set to the bucket's `s3://` URL. It applies both
rules, tests them, and removes them again, so point it at a bucket meant
for testing.

## Providers

The difference between providers is an endpoint, a region and an
addressing style. Monk's suite and `bin/storage_check` ran against
Hetzner; the others are from their own docs, as of 2026-10-26.

| Provider | `endpoint=` | `region=` | Addressing |
|---|---|---|---|
| Hetzner Object Storage | `fsn1.your-objectstorage.com` (also `nbg1`, `hel1`) | the location: `fsn1` | either; both checked |
| Cloudflare R2 | `<ACCOUNT_ID>.r2.cloudflarestorage.com` | `auto` | either |
| Backblaze B2 | `s3.<region>.backblazeb2.com`, e.g. `s3.eu-central-003.backblazeb2.com` | the same region, `eu-central-003` | either |
| AWS S3 | `s3.<region>.amazonaws.com`, e.g. `s3.eu-central-1.amazonaws.com` | `eu-central-1` | host name (the default) |
| MinIO, floci, LocalStack (local) | `http://127.0.0.1:9000` | `us-east-1` | `path_style=1` |

For example:

```sh
STORAGE_URL='s3://KEY:SECRET@my-bucket?endpoint=fsn1.your-objectstorage.com&region=fsn1'
STORAGE_URL='s3://KEY:SECRET@my-bucket?endpoint=ACCOUNT_ID.r2.cloudflarestorage.com&region=auto'
STORAGE_URL='s3://KEY:SECRET@my-bucket?endpoint=http://127.0.0.1:9000&region=us-east-1&path_style=1'
```

R2 and B2 both document CORS and lifecycle rules through the S3 API, as
above. B2 warns that rules set through the S3 API shouldn't then be
edited in its web console.

### Hetzner

Two facts about Hetzner shape any deployment on it:

- **A key pair can access every bucket in its project.** Staging and
  production need separate Hetzner projects, or staging's key can read
  and delete production's files.
- **Nothing is replicated between locations, and `copy` works only
  within a bucket.** A backup is a job that downloads each file and
  uploads it again to a bucket elsewhere. Traffic inside Hetzner's EU
  network is free.

Hetzner's only server-side encryption is SSE-C, where every read must
carry the key. A plain signed link can't, so Monk doesn't support it: an
app that wants files encrypted encrypts them in the browser, and the
bucket stores opaque bytes.

## `file://` on a server

A `file://` URL in staging or production stores files on that host's
disk, and Monk serves them itself, at `/_monk/storage`, the way a bucket
would. It's for one host with a persistent volume and no bucket, and it
costs:

- **One host only.** `bin/server` and `bin/jobs` must share the volume,
  and a second web host wouldn't see the first one's files.
- **Every upload and download holds a worker Ractor**, for as long as
  the bytes take.
- `STORAGE_SECRET` must be set (above), and the volume backed up by
  you.

Files are never stored under `public/`: the asset manifest is frozen at
boot, and in development `public/` is served from disk as trusted
content.

## In development and tests

With `STORAGE_URL` unset, development stores files under
`storage/development` and tests under `storage/test` (both ignored by
git), so a test never touches development's files. The file backend
behaves like a bucket: its links are signed and expire, an upload of
another length or type is refused with 403, a missing file is a 404,
ranges get 206, and every response carries
`X-Content-Type-Options: nosniff`. A mistake a bucket would refuse fails
in a test, not in staging.

Its links are paths on the app (`/_monk/storage/<token>`), so a test
calls them through the booted app:

```ruby
require "rack/mock"

def test_a_stored_file_downloads
  key = Monk::Storage.generate_key(prefix: "check")
  Monk::Storage.put(key, "hello", content_type: "text/plain")

  status, _headers, body = APP.call(Rack::MockRequest.env_for(Monk::Storage.url(key)))

  assert_equal [200, "hello"], [status, body.to_enum(:each).to_a.join]
ensure
  Monk::Storage.delete(key)
end
```

A browser upload in a test is a `PUT` to the `presigned_put` link with
the signed headers:

```ruby
upload = Monk::Storage.presigned_put(key, content_type: "image/png", byte_size: png.bytesize)
env = Rack::MockRequest.env_for(upload.url, method: "PUT", input: png, "CONTENT_TYPE" => "image/png")
status, = APP.call(env)  # 200, or 403 for another type or length
```

Files stay in `storage/test` between runs. Delete what a test stores in
its `ensure` or `teardown`, or the whole directory before the suite.

## What's not here

- An attachments table, a model, or image variants: the app's choice,
  and image processing doesn't work on files encrypted in the browser.
- Multipart uploads to S3: one `PUT` takes up to 5 GB.
- Upload forms without JavaScript (`multipart/form-data`).
- Public buckets and unsigned links: every download goes through a
  route that checks access.
- Event notifications from the bucket: the confirm route is the signal.
