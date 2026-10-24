## storage

**Where:** `config/storage.rb` (from `STORAGE_URL`, `STORAGE_SECRET`);
routes that upload and serve files in `app/routes/storage.rb`. Files live
under `storage/<env>` until `STORAGE_URL` names a bucket.

**Main calls:** `Monk::Storage.generate_key(prefix: "tmp")` for every new
file; `put(key, body, content_type:)`, `get(key, range: 0..99)`,
`head(key)` (an object with `byte_size`, `content_type`, `etag`, or nil),
`delete(key)`, `copy(from, to)`. Downloads: `redirect
Monk::Storage.url(key)`. Browser uploads:
`presigned_put(key, content_type:, byte_size:)` gives the `url` and
`headers` to PUT the file with. At confirm,
`Monk::Storage.get(key, range: Monk::Storage::Sniff::RANGE)` and
`Monk::Storage::Sniff.content_type(bytes)` check the file is what it
claims; `Sniff.refuse_svg!(bytes)` raises on SVG.

**Test:** `test/storage_test.rb`. Tests use `storage/test` (an unset
`STORAGE_URL`); call a signed link through `APP.call` with
`Rack::MockRequest.env_for(Monk::Storage.url(key))`.

**Pitfalls:**
- Keys come from `generate_key`, never from a user's filename: keep the
  filename in the app's own table.
- An upload stays under `tmp/` until the app checks it; then `copy` to
  its final key, and `delete` the `tmp/` one after the copy, never before.
- Check the viewer may see a file before redirecting to its `url`: a
  signed link works for anyone who has it, until it expires.
- Large files go from the browser straight to the bucket with
  `presigned_put`. Don't stream them through a route: it holds a worker
  Ractor for the whole upload.
- Never accept SVG or HTML as an upload: both can carry scripts.

**Examples:** `storage-upload`, `storage-confirm` and `storage-download`
in `app/routes/storage.rb`.
