## storage

Files users send, stored by key. In development and test `STORAGE_URL` is
unset, so files go under this app's `storage/development` and
`storage/test` directories (ignored by git), and Monk serves their signed
links at `/_monk/storage`, the way a bucket would. Nothing to start.

### Before production

Create an S3-compatible bucket (Hetzner Object Storage, AWS S3, Cloudflare
R2, ...) and set `STORAGE_URL`, e.g.
`s3://KEY:SECRET@bucket?endpoint=fsn1.your-objectstorage.com&region=fsn1`.
An unset `STORAGE_URL` fails the boot outside development and test. The
bucket needs a CORS rule allowing `PUT` from `PUBLIC_URL`, so browsers can
upload to it, and a lifecycle rule expiring `tmp/` after a day, so
unconfirmed uploads don't pile up: both are in docs/guides/storage.md in
the monk repo. A `file://` URL works only on one server with a persistent
volume, and then needs `STORAGE_SECRET` set to a random value of its own.

### Check it works

1. `bundle exec rake test` runs `test/storage_test.rb`: a file stored by
   key reads back, and its signed link answers.
2. By hand:
   `bundle exec ruby -r ./config/load -e 'Monk::Storage.put("notes/hello", "Hello"); p Monk::Storage.get("notes/hello")'`
   prints `"Hello"`, and the file is under `storage/development/objects/`.
3. The examples: uncomment `storage-upload`, `storage-confirm` and
   `storage-download` in `app/routes/storage.rb`, restart `bin/server`,
   and upload a PNG:

   ```bash
   curl -X POST http://localhost:9292/uploads -H "content-type: application/json" \
     -d "{\"content_type\": \"image/png\", \"byte_size\": $(wc -c < photo.png)}"
   # PUT the file to the "url" it answers, with the content-type it signed:
   curl -X PUT "http://localhost:9292<url>" -H "content-type: image/png" --data-binary @photo.png
   curl -X POST http://localhost:9292/uploads/confirm -H "content-type: application/json" \
     -d '{"key": "<key>"}'
   # The confirmed key is media/<hex>; open its link:
   curl -iL http://localhost:9292/media/<hex>
   ```

   The last command follows a redirect to a signed `/_monk/storage` link
   and gets the PNG back.
