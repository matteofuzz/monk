# Web push encrypts and signs its own messages, keeps one subscription per browser tied to an auth session, and sends one job per device

An app wants to notify people when it isn't open (roadmap item 4, `docs/plan-pwa-push.md`): a new message, a reply, a reminder. The browser's Push API gives a page a subscription (an endpoint URL at the browser vendor's push service, and two keys), and the app's server POSTs to that endpoint. Every message has to be encrypted for that browser (RFC 8291) and carry a signed token identifying the app (VAPID, RFC 8292). Push services answer 404 or 410 once a subscription is gone: the person turned notifications off, uninstalled the app, or the browser rotated it. On iOS, push only reaches an app installed on the Home Screen, which is why the web app manifest and service worker (`monk add pwa`) ship in the same release.

We decided that `Monk::Push` writes the encryption and the VAPID token itself, over OpenSSL, as `Monk::Storage` signs its own S3 requests; that each subscription is a row tied to the auth session it was made in; and that `Monk::Push.notify` enqueues one job per subscription.

## The crypto, without a gem

- **Why not a gem.** The Ruby web push gems are barely maintained, pull in more than they use, and none was checked under Ractors. What's needed is short: ECDH on P-256, HKDF and AES-128-GCM for the message, an ES256 JWT for VAPID. A spike on 2026-11-13 ran all of it in worker Ractors on Ruby 4.0.6 (openssl gem 4.0.2, OpenSSL 3.5.9).
- **Checked against the RFC.** `test/push_crypto_test.rb` reproduces RFC 8291 Appendix A's message byte for byte, and decrypts random messages the way a browser does, in code written apart from `Push::Encryption`.
- **Keys as raw strings.** OpenSSL 3 keys are immutable, built only from DER, and can't be made Ractor-shareable. So the configuration keeps the base64url bytes browsers use, frozen, and each send rebuilds the keys it needs, which costs far less than the HTTP request. The VAPID JWT is signed for every send for the same reason: a Ractor can't hold a cache.
- **One record, 3993 bytes.** Messages use one `aes128gcm` record of 4096 bytes, what every push service accepts, which leaves 3993 bytes of payload. `notify` checks the size in the caller, before anything is enqueued.
- **A wrong pair fails the boot.** `configure` derives the public key from the private one and compares: a mismatched pair would have every push refused, with nothing at boot to say why.

## A subscription per browser, tied to a session

- **One row per endpoint.** The browser's page re-sends its subscription on every load once notifications are on. An endpoint already stored updates its row (new keys, new session), so the same browser never makes two rows, and a rotated endpoint heals on the next visit. `pushsubscriptionchange`, the Push API's own event for this, is unevenly supported, and a service worker can't send the CSRF token.
- **Tied to the session it was made in.** `push_subscriptions.session_id` references `sessions (id) ON DELETE CASCADE`. Notifications go to the devices where the person is signed in: logging out on a shared computer stops that computer's notifications even if the logout's request never reached the server, and a device that signs in as someone else moves to them. A revoked session's rows stop counting at once (every read joins `sessions`), an expired one's go when `Monk::Auth.sweep!` deletes it, and `Monk::Push::Sweep` clears the rest nightly. This makes `push` depend on `auth`: subjects come from auth anyway.
- **The endpoint is a secret.** Whoever knows it can send to the browser (with the keys) or unsubscribe it. It's never logged: logs and errors carry the endpoint's host only.

## One job per device

- **Why per device.** A person with a phone and a laptop gets two jobs. If one push service is down, only that send is retried, and a 410 deletes exactly its row. One job per person would resend to every device on any failure.
- **What each answer means.** 2xx records `last_success_at`. 404 and 410 delete the row and the job succeeds. 400, 401, 403 and 413 are final (`RejectedError`, in `never_retry`): retrying sends the same request. 401 and 403 are logged as a VAPID problem, since a wrong key or contact is the usual cause. 429, 5xx and network errors are retried with the jobs' own backoff; `Retry-After` isn't honoured, because the jobs API has no per-error delay.
- **Checked again when the job runs.** A job whose subscription stopped counting since it was enqueued (session revoked, row gone) sends nothing.

## The browser side

- `push.js`, served from the gem, follows Live's client: no JS API, `data-push-enable` and `data-push-disable` buttons, the state as `<html data-push-state>` and `monk-push:state` events. It asks for permission inside the click, as iOS requires. A person's "off" is remembered in that browser, so page loads don't subscribe it again.
- pwa's `sw.js` shows every push as a notification and opens its URL on a click, same-origin only. iOS and Chrome penalise a push that shows nothing, so there are no silent pushes. The handlers are in `sw.js` from `monk add pwa`, active: they do nothing until a subscription exists.
- `sw.js` has no `fetch` handler, so it never answers Live's resync refetch (ADR 0011), a login redirect or a `/_monk/` path from a cache.

## Consequences

- Push depends on `auth`, `jobs` (and so `postgres`) and `pwa`.
- Changing an app's VAPID pair ends every subscription; browsers subscribe again on their next visit, while notifications are allowed.
- Headless Chrome reaches no push service, so subscribing end to end is checked on devices, not in the suite. The suite delivers to a push service stood up on loopback, and delivers a message to `sw.js` through DevTools.
- `monk check` (0.26) can check a deployed environment's VAPID settings; the boot already refuses a mismatched pair.
