# Monk::Mail.deliver_later (docs/adr/0014). Loading monk/mail and
# monk/jobs is enough -- the second one loads it (docs/adr/0017) -- so
# this file only exists for apps whose config/jobs.rb still requires it.
require_relative "../mail"
require_relative "../jobs"
