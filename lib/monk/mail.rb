require_relative "mail/errors"
require_relative "mail/address"
require_relative "mail/mime"
require_relative "mail/message"

module Monk
  # Sending email. Opt-in: require "monk/mail" explicitly -- `require
  # "monk"` alone does not load this. Text and/or HTML messages only, MIME
  # built by Monk itself, since the `mail` gem can't run inside a worker
  # Ractor (docs/adr/0012-minimal-built-in-mailer.md).
  module Mail
  end
end
