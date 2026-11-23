# Web push — `Monk::Push`

Notifications to the devices where a signed-in person turned them on,
whether or not the app is open: a new message, a reply, a reminder. Sent
from jobs, one per device. Why it's built this way: ADR 0020.

```
monk add push
```

adds `pwa`, `jobs` and `auth` first if they're missing, and writes:

- `config/push.rb`: `Monk::Push.configure` with the VAPID key pair, a
  contact, and the subscribe route's path;
- a fresh VAPID pair in `.env`, and another in `.env.test` (the contact
  is `PUBLIC_URL` unless `VAPID_CONTACT` is set);
- a migration for `push_subscriptions` (`bin/setup_db` runs it);
- `app/routes/push.rb`: the examples `push-subscribe` and `push-notify`;
- `app/views/push/_settings.erb`: a switch to turn notifications on and
  off;
- `test/push_test.rb`.

The nightly `Monk::Push::Sweep` is already in the `config/recurring.rb`
that `monk add jobs` writes, behind `if defined?(Monk::Push::Sweep)`: it
starts running once push is installed.

## Turning it on

1. Uncomment `push-subscribe` in `app/routes/push.rb`. The page stores
   each browser's subscription through it: `POST` on every page load once
   notifications are on, `DELETE` when they're turned off.
2. Render the switch in a page for signed-in people:

   ```erb
   <%= render "push/_settings", layout: false %>
   ```

3. Send:

   ```ruby
   Monk::Push.notify(recipient, { title: "Ann", body: "Lunch?", url: "/chats/7", tag: "chat-7" })
   ```

`public/sw.js` (pwa) shows the notification. A click on it brings the
app to `url` (this app's own pages only): a window already there comes
forward, otherwise the app's open window goes there, and a new one opens
only when the app has none. Where the app is installed, the click goes
to the app, never to a browser tab left open from before: with no app
window open, a new one opens (Android and desktop Chrome open it in the
app). After the app is uninstalled, a click opens a new tab rather than
reusing one. A newer notification with the same `tag` replaces the
older one.

## Sending

```ruby
Monk::Push.notify(subject, payload, ttl: 86_400, urgency: nil, topic: nil, conn: nil)
```

- Enqueues one `Monk::Push::DeliveryJob` per device where `subject` is
  signed in and turned notifications on, and returns how many (0 for
  someone with none). The jobs are on the `push` queue: `bin/jobs` takes
  it when `JOBS_QUEUES` lists it, as `monk add jobs` writes it
  (`mailers,push,default`).
- `payload`: a Hash (sent as JSON) or a String, at most 3993 bytes:
  checked here, so too large raises `PayloadTooLargeError` in the caller.
  Send an id and a short text, not a whole record.
- `ttl:` how long (seconds, up to 28 days) a push service keeps the
  message for a device that's offline; a day by default, 0 for now or
  never. `urgency:` `very-low`, `low`, `normal` or `high`. `topic:` up to
  32 base64url characters: a newer message with the same topic replaces
  one still waiting for the device.
- `conn:` enqueues inside the caller's transaction, so the notification
  commits or rolls back with the app's own writes.

Each job encrypts the message for its browser, signs it, and POSTs it to
the browser's push service:

| The push service answers | Then |
|---|---|
| 2xx | done (`last_success_at` is set) |
| 404, 410 | the subscription is gone (turned off, app uninstalled): its row is deleted |
| 401, 403 | final, logged as an error: check `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_CONTACT` |
| 400, 413 | final |
| 429, 5xx, no answer | retried, with the jobs' backoff |

`Monk::Push.deliver(subscription, payload, ...)` sends one now, in the
calling process, and returns `:delivered` or `:gone`.

## Who is subscribed

```ruby
Monk::Push.subscribed(["ann@example.com", "bob@example.com"])
# => {"ann@example.com" => true, "bob@example.com" => false}
Monk::Push.subscribed?("ann@example.com")
Monk::Push.subscriptions("ann@example.com") # [{ id:, subject:, endpoint:, p256dh:, auth: }]
```

`subscribed` is one query for a list of people, shaped like
`Monk::Presence.status`: whether a notification would reach at least one
of their devices.

## Subscriptions belong to sessions

A subscription is stored for the auth session it was made in, and counts
only while that session does:

- logging out, or `Monk::Auth.revoke`/`revoke_all`, stops that session's
  notifications at once;
- an expired session's rows go with it when `Monk::Auth.sweep!` deletes
  it;
- a shared device that someone else signs in to moves to them on its next
  page load;
- `Monk::Push::Sweep` (nightly) deletes the rows that no longer count,
  and those past the browser's own `expirationTime`.

`Monk::Push.subscribe(session_token:, subscription:, user_agent:)`, which
`push-subscribe` calls, returns `nil` without a valid session (answer
401), and raises `InvalidSubscriptionError` for a subscription a browser
wouldn't send (answer 422).

## The page

`push.js`, loaded by `<%= monk_head %>`, does the browser's part:

- `[data-push-enable]` asks for permission (inside the click: iOS only
  asks then) and subscribes; `[data-push-disable]` unsubscribes, and the
  browser remembers it, so later page loads don't subscribe it again;
- every page load with notifications allowed re-sends the subscription,
  which keeps the server's row current;
- a subscription made with an older VAPID key is replaced;
- the state is set as `<html data-push-state="...">` and sent as
  `monk-push:state` (`{ state }`): `off`, `subscribed`, `denied`
  (blocked in the browser's settings), `needs-install` (iOS in a Safari
  tab), `unsupported`. Failures come as `monk-push:error` (`{ message }`).
  `_settings.erb` uses the attribute to show the right button and note;
- a page loaded after notifications were blocked in the browser's
  settings tells the server to forget its subscription (not as "off":
  allowing them again subscribes on the next load).

## Keys

- `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY`: a P-256 pair, base64url.
  `monk push keys` prints a new one (`--json` too). Each environment has
  its own. The boot fails if the private key isn't the public key's.
- `VAPID_CONTACT`: a `mailto:` or `https:` URL where push services can
  reach you, on a real domain; `PUBLIC_URL` when it's unset. Apple
  refuses every push signed with a contact on `localhost`, an IP or a
  placeholder domain (`.example`, `.test`), answering 403
  `BadJwtToken`: outside development and test, `configure` refuses one
  at boot.
- Changing a deployed app's pair ends every subscription: the push
  services refuse the old ones. Browsers with notifications allowed
  subscribe again on their next visit.

## Platforms

- **iPhone and iPad:** iOS 16.4 and later, only in an app added to the
  Home Screen ([`pwa.md`](pwa.md)). In a Safari tab the state is
  `needs-install`. Adding the app copies Safari's login into it, so sign
  in in Safari first. Apple keeps accepting messages (201) for an app
  that was deleted, or whose notifications were blocked in Settings
  (checked for half an hour): its row goes when its session ends
  (logout, expiry), or, when blocked, on the app's next page load.
- **Android, desktop Chrome, Edge, Firefox, macOS Safari:** in the
  browser, no install needed. macOS Safari shows notifications even
  while Safari is quit. Notifications blocked in its website settings
  take effect when the page next loads (that load also forgets the
  subscription); until then, an open page still shows them. Firefox
  shows nothing while quit: the push service keeps the message for its
  `ttl:`, and Firefox shows it when it starts again. On a Mac, each
  browser also needs its notifications allowed in System Settings ▸
  Notifications; a push the browser accepted (201) shows nothing
  otherwise.
- Everywhere, https (or `localhost`) and a service worker: pwa.

## Testing

`Monk::Push.notify` returns 0 for someone with no subscription, and
enqueued jobs run with `Monk::Jobs.drain!`. Monk's own suite delivers to a
push service stood up on loopback, decrypting each message as a browser
would. Headless Chrome reaches no real push service, so subscribing end
to end is checked on devices.

## Pitfalls

- Every push must show a notification, and `sw.js` always does. Don't
  send "silent" pushes: iOS stops delivering after a few.
- Never log a subscription's endpoint: it's the browser's secret URL.
  Monk's own logs carry the host only.
- `VAPID_PRIVATE_KEY` is a secret, like `AUTH_SECRET`.
