## push

Notifications to the devices where a signed-in person turned them on,
sent from jobs (`bin/jobs`, jobs above). `.env` and `.env.test` already
have a VAPID key pair of their own, made by `monk add push`.

### Turn it on

1. Uncomment `push-subscribe` in `app/routes/push.rb`: push.js stores each
   browser's subscription through it.
2. Put the switch in a page for signed-in people:
   `<%= render "push/_settings", layout: false %>`.
3. Send from a route or a job:
   `Monk::Push.notify(subject, { title: "Ann", body: "Lunch?", url: "/chats/7" })`.
   `public/sw.js` (pwa) shows it, and opens `url` on a click.

### Before production

- `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY`: `monk push keys` prints a
  pair; each environment gets its own. Keep it: a new pair ends every
  subscription (browsers subscribe again on their next visit).
- `VAPID_CONTACT`: a `mailto:` or `https:` URL where push services can
  reach you. Apple refuses pushes without one.
- https everywhere, and `bin/jobs` running: every notification is a job.
- On iPhone and iPad, notifications only reach the app once it's added to
  the Home Screen (iOS 16.4 and later); the switch says so in Safari.

### Check it works

1. `bundle exec rake test` runs `test/push_test.rb`: the key pair is
   loaded, the table exists, and pages give the browser the key.
2. By hand, in Chrome, with `bin/server` and `bin/jobs` running: log in,
   press "Turn on notifications", allow them, then uncomment `push-notify`
   and, from the page's console:

   ```js
   fetch("/push/test", { method: "POST", headers: { "x-csrf-token":
     document.cookie.match(/csrf_token=([^;]+)/)[1] } })
   ```

   A notification appears; clicking it opens the app.
