# Plan: downloads the browser caches (0.28.1, 0.28.2)

Status: planned 2026-11-25, from an app's staging check: avatars,
`<img src="/photos/<name>">` redirecting to `Monk::Storage.url(key)`,
showed their initials first on every page load. 0.28.1 released
2026-11-25. Its cached redirect failed in the installed iPhone app:
0.28.2 below reverses it. Left: the staging check in "Done when".

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

## 0.28.2: the route is never cached

From the same app's staging (2026-11-25), Hetzner, iOS 26, installed on
the Home Screen: with the route's 302 cached `private, max-age=3600`,
photos failed after ~30 minutes in the background and after a
swipe-close and reopen. The app sent no request to the route (it
followed its cached 302), and the link that 302 pointed to still
answered 200. Safari and desktop Chrome on the same photo worked. No
WebKit bug matches exactly; its memory cache has a history with
redirects (bugs 77538, 131757). Not yet confirmed with Web Inspector.

The rule, from the person's side: reopening the app shows the current
photos, without downloading the unchanged ones again.

- The route sets `cache-control: no-store` first: its 404 and its
  redirect alike (`halt` and `redirect` keep headers already set). A
  404 without it may be cached heuristically and hide a file uploaded
  after it.
- Only the bytes are cached, at the signed link (0.28.1), the same URL
  for a whole `cache_window`.
- A changed file gets a new key, so the route redirects to a new link
  and the browser fetches it fresh. A longer `cache_window` (a day) for
  avatars, if the refetch each hour shows.

Changed: `docs/guides/storage.md` (the example and "Caching"), the
scaffold's `storage-download` example, the storage `agents.md`, the
CHANGELOG, and `upgrading.md` (a 0.28.2 step; 0.28.1's step marked
replaced). No code: the template ships in the gem, hence a release.

## Done when

- 0.28.1: both changes in, tests pass, the guide updated. Done.
- On the app's staging, installed iPhone app, with the route `no-store`
  and the bytes cached: photos show after time in the background and
  after a swipe-close and reopen; a photo uploaded or replaced shows on
  the next load; no initials flash on a page change within the hour.
  Checked before calling it done.
