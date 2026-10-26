require "monk"
require "monk/storage"

# Stores the files users send with Monk::Storage: put, get, head, delete
# and copy by key, signed download links (url) and uploads that go from
# the browser straight to the bucket (presigned_put). See
# docs/guides/storage.md in the monk repo. Loaded by config/load.rb.
Monk::Settings.configure do
  # Where files go. Unset in development and test means
  # file://storage/<env>, files under this app's storage/ directory, which
  # Monk serves at /_monk/storage; anywhere else an unset one fails the
  # boot. In production an S3 bucket, e.g.
  # s3://KEY:SECRET@bucket?endpoint=fsn1.your-objectstorage.com&region=fsn1
  optional :storage_url, default: ""
  # Signs the file backend's links. Only needed with a file:// URL outside
  # development and test (one server with a persistent volume); a bucket
  # signs its own. A random value of its own, not AUTH_SECRET.
  optional :storage_secret, default: ""
end

Monk::Storage.configure(url: Monk::Settings[:storage_url], secret: Monk::Settings[:storage_secret])
