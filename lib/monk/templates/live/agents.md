## live

**Where:** `config/live.rb` (subscribe rules, `live_ws_url`), broadcasts in
`app/broadcasts/`, the partials they push in `app/views/` (e.g.
`app/views/live/`), the routes calling them in `app/routes/`.

**Main calls:** in a view, `<div <%= live_topic "topic" %>>`; from a route,
job or broadcast, `Monk::Live.patch(topic, to: "#id", partial: "live/_x",
**locals)`, also `append`, `prepend`, `remove(topic, to:)`, `batch`. Rules:
`Monk::Live.authorize("contacts:*") { |subject, topic| ... }` with a block
built in a module, `anonymous: true` to let visitors in.

**Test:** `test/live_test.rb` publishes and checks a subscribed socket gets
it. To test a page, render it and look for `data-live-topic`.

**Pitfalls:**
- Nothing can be subscribed to until a rule in `config/live.rb` allows it;
  rules are checked in `bin/websocket_server`, which never loads `app/`.
- A pushed partial sees only its locals (`locals[:text]`), never `params`
  or the session.
- Each topic name must match what pages subscribe to, exactly.
- The demo (`/demo/live`) is development only; delete it when done.

**Examples:** `live-rule` in `config/live.rb`; `live-broadcast` in
`app/broadcasts/greeting.rb` and `app/routes/live.rb`.
