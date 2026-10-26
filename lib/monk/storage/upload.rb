module Monk
  module Storage
    # What presigned_put returns: the URL the browser PUTs the file to, and
    # exactly the headers it must send with it. Content-Type and
    # Content-Length are inside the signature, so the bucket refuses any
    # other (browsers set Content-Length themselves; it's listed for
    # clarity).
    Upload = Data.define(:url, :headers)
  end
end
