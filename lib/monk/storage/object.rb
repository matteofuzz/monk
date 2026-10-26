module Monk
  module Storage
    # What head returns for a stored object. etag is the bytes' MD5 in hex,
    # without the quotes S3 puts around it.
    Object = Data.define(:key, :byte_size, :content_type, :etag)
  end
end
