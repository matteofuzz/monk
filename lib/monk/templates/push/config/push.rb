require "monk"
require "monk/push"
require_relative "persistence"

# Web push (monk add push): notifications to the devices where a signed-in
# person turned them on. Loaded by config/load.rb. configure checks that the
# VAPID private key goes with the public one, so a wrong pair fails the boot
# rather than every push later. Each environment has its own pair:
# `monk push keys` makes one. Changing a deployed app's pair ends every
# subscription it has; browsers subscribe again on their next visit.
Monk::Push.configure(
  db_name: :primary,
  public_key: ENV["VAPID_PUBLIC_KEY"],
  private_key: ENV["VAPID_PRIVATE_KEY"],
  contact: ENV["VAPID_CONTACT"],  # mailto: or https:, for push services to reach you
  path: "/push/subscription",     # the push-subscribe route (app/routes/push.rb)
)
