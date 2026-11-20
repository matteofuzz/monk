## presence

**Where:** `config/presence.rb` (`Monk::Presence.configure`, `on_change`),
the dot partial in `app/views/presence/_dot.erb`. Counted in
`bin/websocket_server`, reacted to in `bin/server` (`config.ru`).

**Main calls:** `Monk::Presence.status(subjects)` →
`{subject => {status: :online | :away | :offline, last_seen_at:}}`, one
query for all of them; `Monk::Presence.online?(subject)`. Subjects are
Monk::Auth's (the user's email). `Monk::Presence.on_change { |changes| ... }`
with a block built in a module, receiving the same hash for the people
whose status changed.

**Test:** `test/presence_test.rb` reads the status of someone with no page
open.

**Pitfalls:**
- Only signed-in sockets count; a visitor is never online.
- `online?` is false once every page is hidden or closed (a closed page
  reads away for the grace, then offline): send a push when it's false.
- `on_change` runs in its own Ractor in `bin/server`: build its block in a
  module body; it sees no request, params or session.
- `on_change` gets a batch: push one Live message per batch (or per 50),
  not one per person, or a burst fills the `:notify` pool and drops
  patches.
- A change is reported at most once: one that happens while no
  `bin/server` runs is never reported. Render the current status when a
  page loads, and use `on_change` only to update it.
- Status is read from the primary database, not a replica.

**Examples:** `presence-dots` in `config/presence.rb`.
