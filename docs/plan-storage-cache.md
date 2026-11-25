# Plan: downloads the browser caches (0.28.1)

Status: planned 2026-11-25, from an app's staging check: avatars,
`<img src="/photos/<name>">` redirecting to `Monk::Storage.url(key)`,
showed their initials first on every page load. Built 2026-11-25
(both changes, tests, guide); left: the staging check in "Done when".

## The problem

A download is two requests: the app's route (302), then the signed link.

- **The signed link:** the file backend answers `cache-control: private,
  max-age=<seconds left>` (`lib/monk/storage/routes.rb:59`). An S3
  bucket answers with no `Cache-Control` (checked on Hetzner: `etag` and
  `last-modified` only), so the browser guesses. `url`'s promise
  (`lib/monk/storage.rb:103`, "the browser's cache works") holds for the
  file backend only.
- **The redirect:** a 302 with no `Cache-Control` isn't cached, so every
  page load asks the app again before the image can show. The guide's
  Downloads example sets none.
- **Both are needed:** with the app's redirect cached an hour
  (2026-11-25), an iPhone still showed the initials before the photo on
  every page load: the bucket's uncached response alone is enough to
  cause it.

## The change

1. **The redirect, in the guide** (Downloads): the route sets
   `headers["cache-control"] = "private, max-age=#{expires_in}"` before
   `redirect`, which keeps headers already set
   (`lib/monk/context.rb:71`). No new API.
   - Safe: a cached redirect points to a link valid at least
     `expires_in` longer.
   - The trade-off, said in the guide: someone whose access is revoked
     may keep seeing the file up to `expires_in`, as the signed link
     already allows.
2. **The signed link** (`Backends::S3#url`,
   `lib/monk/storage/backends/s3.rb:100`): sign
   `response-cache-control=private, max-age=<expires_in>` into the query
   (`SigV4.presign` takes `query:`; `canonical_query` encodes the comma
   and space). The bucket answers with that header.
   - `expires_in`, not the seconds left: the value is fixed at signing,
     and a link fetched anywhere in its window is valid at least
     `expires_in`. The file backend keeps sending the seconds left; the
     guide says why they differ.
   - No `cache_control:` override: the URL changes every `cache_window`
     and the browser caches by URL, so a longer max-age caches a URL the
     page stops using within the hour.

## Tests

- `test/storage_s3_backend_test.rb`: the link carries
  `response-cache-control`, inside the signature (changing it breaks
  it).
- `test/storage_s3_integration_test.rb`: floci answers with the header.
  If floci ignores the parameter, this plan says so instead of skipping
  the test.

## Docs

- `docs/guides/storage.md`, Downloads: the route's `cache-control` in
  the example, the revoked-access trade-off, and "write a new key when
  the content changes": a file replaced under the same key stays cached
  up to `expires_in` plus the cached redirect (both backends).
- Providers checked: Hetzner (Ceph RGW), floci; AWS documents the
  parameter; MinIO, R2 unchecked. One that ignores it is harmless (no
  header, as today). The guide promises caching only where checked.

## Done when

- Both changes in, tests pass, the guide updated.
- On the app's staging, with the redirect cached (done app-side already,
  `max-age=3600`) and the new link: avatars no longer flash their
  initials on a page change. Checked before calling it done.
