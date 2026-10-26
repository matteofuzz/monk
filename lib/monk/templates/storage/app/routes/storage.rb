# Routes that store files users send (monk add storage). An upload goes
# from the browser straight to the bucket (or, in development, to
# /_monk/storage): bin/server only signs the link, then checks the file.
#
# monk:example storage-upload -- a signed link to upload one file to
# # Only the types and sizes the app accepts get a link, and both are
# # inside its signature. The file goes under tmp/ until it's confirmed.
# # Try it (in development the link is a path on this app):
# #   curl -X POST http://localhost:9292/uploads -H "content-type: application/json" \
# #     -d "{\"content_type\": \"image/png\", \"byte_size\": $(wc -c < photo.png)}"
# #   curl -X PUT "http://localhost:9292<url>" -H "content-type: image/png" --data-binary @photo.png
# class App
#   post("/uploads") do
#     content_type = params[:content_type].to_s
#     byte_size = params[:byte_size].to_i
#     halt 422, "type not accepted" unless %w[image/png image/jpeg image/webp application/pdf].include?(content_type)
#     halt 422, "size not accepted" unless byte_size.between?(1, 10 * 1024 * 1024)
#
#     key = Monk::Storage.generate_key(prefix: "tmp")
#     upload = Monk::Storage.presigned_put(key, content_type: content_type, byte_size: byte_size)
#     json(key: key, url: upload.url, headers: upload.headers)
#   end
# end
# monk:end
#
# monk:example storage-confirm -- check an upload, then move it out of tmp/
# # head, check the first bytes, copy, then delete: if a step fails, the
# # tmp/ file stays and the bucket's lifecycle rule expires it. A real app
# # also checks who uploaded it, and saves a record (key, filename, type,
# # size) in its own table: docs/guides/storage.md in the monk repo.
# #   curl -X POST http://localhost:9292/uploads/confirm -H "content-type: application/json" \
# #     -d '{"key": "tmp/<key>"}'
# class App
#   post("/uploads/confirm") do
#     key = params[:key].to_s
#     halt 422, "not an upload" unless key.match?(%r{\Atmp/[0-9a-f]{32}\z})
#     object = Monk::Storage.head(key)
#     halt 404, "no such upload" unless object
#
#     # Also refuses SVG, which can carry scripts: Sniff never names it.
#     first_bytes = Monk::Storage.get(key, range: Monk::Storage::Sniff::RANGE)
#     unless Monk::Storage::Sniff.content_type(first_bytes) == object.content_type
#       Monk::Storage.delete(key)
#       halt 422, "the file isn't a #{object.content_type}"
#     end
#
#     media_key = key.sub("tmp/", "media/")
#     Monk::Storage.copy(key, media_key)
#     Monk::Storage.delete(key)
#     json(key: media_key, content_type: object.content_type, byte_size: object.byte_size)
#   end
# end
# monk:end
#
# monk:example storage-download -- a redirect to a file's signed link
# # NO ACCESS CHECK: anyone who knows a key gets the file. In a real app
# # this becomes GET /media/:id, which looks the record up, checks the
# # viewer may see it, then redirects to its key's link.
# #   curl -i http://localhost:9292/media/<key without media/>
# class App
#   get("/media/*") do
#     halt 404, "" unless params[:splat].match?(/\A[0-9a-f]{32}\z/)
#
#     redirect Monk::Storage.url("media/#{params[:splat]}")
#   end
# end
# monk:end
