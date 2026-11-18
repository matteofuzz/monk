## push

**Where:** `config/push.rb` (VAPID pair, contact, the subscribe route's
path), `app/routes/push.rb` (subscribe/unsubscribe, a test send),
`app/views/push/_settings.erb` (the on/off switch), the handlers at the
end of `public/sw.js` (pwa), the `push_subscriptions` table.

**Main calls:** `Monk::Push.notify(subject, { title:, body:, url:, tag: },
ttl:, urgency:, topic:)` enqueues one `Monk::Push::DeliveryJob` per
device and returns how many; `Monk::Push.subscribed(subjects)` gives
`{ subject => true/false }` for a list of people in one query;
`subscribed?(subject)` for one.

**How it works:** a subscription belongs to the auth session it was made
in: logging out, a revoked session or an expired one stops its
notifications. A device that has gone (the push service answers 404/410)
is deleted by its job. `Monk::Push::Sweep` clears the rest nightly
(`config/recurring.rb`).

**Test:** `test/push_test.rb`. In a test, `Monk::Push.notify` returns 0
for someone with no subscription; enqueued jobs run with
`Monk::Jobs.drain!`.

**Pitfalls:**
- A payload is at most 3993 bytes once JSON (`PayloadTooLargeError`):
  send an id and a short text, not the whole record.
- Every push must show a notification: `sw.js` always does. Don't send
  "silent" pushes; iOS stops delivering after a few.
- Never log a subscription's endpoint: it's the browser's secret URL.
- The VAPID private key is a secret, like `AUTH_SECRET`.
