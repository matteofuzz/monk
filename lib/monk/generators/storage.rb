# Files users send (Monk::Storage): local files in development and test,
# an S3-compatible bucket in production. No service to start, no migration
# and no JS: the upload flow comes as commented routes driven with curl,
# and the guide carries the uploads table and browser code
# (docs/history/plan-storage.md Phase 8).
Monk::Generator.define(:storage) do
  summary "File storage (local files in development, an S3 bucket in production)"
  installed_if "config/storage.rb"

  copy "config/storage.rb", role: :wiring
  copy "app/routes/storage.rb", role: :example
  copy "test/storage_test.rb", role: :test

  # Unset STORAGE_URL is file://storage/<env> in development and test, so
  # neither .env file needs a line, and tests never touch development's
  # files.
  env :example, { "STORAGE_URL" => "s3://KEY:SECRET@bucket?endpoint=fsn1.your-objectstorage.com&region=fsn1",
                  "STORAGE_SECRET" => "only-with-file-urls-a-random-hex-value", }, commented: true
  ignore "/storage/"

  setup_section "storage/setup.md"
  agents_section "storage/agents.md"
  set_before_production "STORAGE_URL", "an S3 bucket; file:// only on one server with a persistent volume"
  set_before_production "STORAGE_SECRET", "only with file://: signs its links"
  example "storage-upload", todo: "uncomment, and set the types and sizes this app accepts"
  example "storage-confirm", todo: "uncomment, and save a record of each file in the app's own table"
  example "storage-download", todo: "uncomment, then replace with a record lookup and an access check"
end
