# Roadmap

Features to add. Not a commitment: each one gets its own design doc and plan
when work on it starts.

- **Scheduled jobs.** Recurring jobs on a cron-like schedule in `Monk::Jobs`.
  One-off delayed jobs already exist (`enqueue(..., wait:)` / `at:`); recurring
  ones were left out of the first version (`docs/guides/jobs.md`, "What's not
  here").
- **File storage, `Monk::Storage`.** An opt-in storage layer configured by
  one `STORAGE_URL`. It has one S3-compatible backend (Hetzner, R2, B2, AWS,
  MinIO) that signs its own SigV4 requests, and local files in development and
  test. Browsers upload straight to the bucket through a presigned PUT, and
  downloads go through an app route that redirects to a signed link. Designed
  in ADR 0016, which is on the `main_dev/monk_storage` branch for now. Before
  the S3 backend ships, four open items need checking on a real Hetzner
  bucket: the signed `Content-Length`, CORS for `PUT`, the `tmp/` lifecycle
  rule, and same-bucket copy.
- **Richer HTML support, forms first.** Views offer only `render`, `h`,
  `raw` and `asset_path`, with no form helpers (`docs/design/views.md`
  deliberately left them out). Templates write every form by hand, including
  its CSRF field and the values to fill back in after a failed submit.

## To evaluate

Gaps that any real app built on Monk runs into and that belong in Monk
rather than in each app. To be evaluated before they become features.

- **Presence: is this person connected?** Only the WebSocket server knows
  who has a socket open, and presence is listed as missing in
  `docs/guides/live.md`. A valid session only means "logged in somewhere", not
  "online". Monk would track connected subjects, remove them on disconnect or
  timeout, and share them across processes through the fanout.
- **WebSocket behaviour on mobile.** A heartbeat or ping timeout,
  reconnecting after a tab is backgrounded or suspended, and resyncing on
  `visibilitychange`. These belong in the Live client and the WebSocket
  server, not in each app's JS.
- **Web push, `Monk::Push`.** VAPID keys, storing subscriptions, sending from
  a job, and deleting subscriptions the push service reports as gone
  (404/410). Nothing in it is specific to one kind of app, and it makes a PWA
  useful to any Monk app.
- **PWA scaffolding.** A web app manifest and a `sw.js` served at the root
  scope, without getting in the way of the Live client. Small, and best done
  together with web push.
- **Cleaning up `Monk::Auth`'s own tables.** `sessions` and `login_tokens`
  belong to `Monk::Auth`, and expired rows pile up in every app, roughly one
  session a month per active person. `Monk::Auth` should ship the cleanup as
  a scheduled job, so this waits for scheduled jobs.
- **An index on `sessions (subject)`.** Any app that looks up a person's
  sessions needs it, including a future "log out everywhere". Today each app
  has to add it in its own migration; it belongs in Monk's auth schema.
- **A rate limit on login emails.** `docs/guides/auth.md` leaves "your
  per-email rate limit" to the app, but every app with magic links needs one.
  It takes one table and one upsert, small enough to move into `Monk::Auth`.

## Other work

Not features, but important.

- **Monk vs. Rails analysis.** A proper comparison with Rails: what Monk
  covers, what it leaves out, and when to choose one over the other.
  `docs/framework-comparison.md` is a starting point, but it measures
  footprint and complexity against Sinatra and Rails rather than going into
  depth.
- **A GitHub Pages site for the project**, set up after the Rails analysis.
