# Bug: `Secure` session cookie is silently dropped in dev over plain HTTP

> **Historical document.** It records how this was planned or built at the time and may describe things that have since changed or shipped. For how Monk works today, see [`docs/guides/`](../guides/).

Status: reported 2026-09-18, not yet fixed. Found during manual testing
of `monk_talk`'s V0-1-1 single-socket chat refactor
(`monk_talk/doc/v0-1-1_single-socket_refactor_plan.md`, "Post-
implementation manual-test findings"). Targeted at the next patch
release after 0.12.4.

## Symptom

Clicking the dev-mode magic link in **Safari Private Browsing** does not
log the user in. The browser lands back on `/` still logged out, with no
error shown anywhere — not in the server log, not in the browser
console, not as an HTTP error. It looks like the token redeem silently
failed.

It doesn't. `Monk::Auth.redeem` succeeds and the session row is created
exactly as it would in any other browser. The cookie carrying that
session is what never survives.

## Root cause

`Auth::Helpers#add_response_cookie` hardcodes the `Secure` flag on every
cookie it sets, unconditionally:

```ruby
# lib/monk/auth/helpers.rb
def add_response_cookie(name, value, http_only:, max_age:)
  flags = ["Path=/", "Secure", "SameSite=Lax", "Max-Age=#{max_age}"]
  flags << "HttpOnly" if http_only
  headers["set-cookie"] = Array(headers["set-cookie"]) + ["#{name}=#{value}; #{flags.join("; ")}"]
end
```

`Secure` cookies are, by spec, only supposed to be set over HTTPS — but
`bin/server` serves dev over plain `http://localhost:PORT`
(`docs/guides/deploying.md`'s "in production a reverse proxy terminates TLS" is
explicitly a *production* concern; dev has no TLS at all). Chromium and
Firefox both special-case `localhost` (and `127.0.0.1`) as a
"potentially trustworthy origin" and accept a `Secure` cookie set over
plain HTTP there anyway, as a documented carve-out for local
development. **Safari does not extend that exception the same way, and
is stricter still in Private Browsing** — it accepts the `Set-Cookie`
response header but never actually stores the cookie, since the
connection isn't HTTPS. Every other browser this framework has been
manually tested against (Chrome, curl, and this app's own `chat.js` dev
loop) happened to mask the bug.

This is why it went unnoticed through 0.12.0–0.12.4: nothing in the test
suite or prior manual testing exercised Safari specifically, and the
failure produces no error on either side of the connection — the cookie
is simply absent on the next request, which is indistinguishable from
"user never logged in" unless you already suspect the cookie layer.

### Downstream effect

Any route behind `require_user!`/`current_subject` will `401`/act logged
out for an affected user, even though they went through the login flow
and the server thinks they have a valid session — with no error visible
anywhere, for the same reason described above.

(An earlier draft of this doc speculated that a separate `monk_talk`
manual-test finding — a message sent to someone not showing up once
they log in — was downstream of this same bug. That's ruled out: the
`monk_talk` finding happened in Firefox, which doesn't have Safari's
strict `Secure`-over-`http://localhost` behavior and accepts the cookie
fine, same as Chrome. It turned out to be unrelated and has since been
root-caused and fixed entirely inside `monk_talk`
(`monk_talk/doc/v0-1-1_single-socket_refactor_plan.md`'s
"Post-implementation manual-test findings") — a client bug, not
this one. It did surface a separate framework-adjacent gap worth
flagging on its own: Kino's router matches `:peer`-style dynamic path
segments against the raw, still-percent-encoded path — `%40` in a path
segment never matches a literal `@`, confirmed live (identical request,
`200` either way, one returns real data and the other comes back
empty). Not written up as its own bug doc here since the fix that
mattered was entirely client-side (stop over-encoding), but any Monk app
that builds a dynamic-segment URL client-side with `encodeURIComponent`
and expects the server to decode it back would hit the same thing.)

## Proposed fix

Make `Secure` conditional on the request actually being HTTPS, instead
of unconditional. `Monk::Context#env` already exposes the Rack env
(`attr_reader :env`, `lib/monk/context.rb`), and `config.ru` in
`monk_talk` already reads `env["rack.url_scheme"]` for exactly this kind
of scheme check (its dev magic-link construction) — so the same signal
is available inside `Auth::Helpers` with no new plumbing:

```ruby
def add_response_cookie(name, value, http_only:, max_age:)
  flags = ["Path=/", "SameSite=Lax", "Max-Age=#{max_age}"]
  flags << "Secure" if env["rack.url_scheme"] == "https"
  flags << "HttpOnly" if http_only
  headers["set-cookie"] = Array(headers["set-cookie"]) + ["#{name}=#{value}; #{flags.join("; ")}"]
end
```

Behind a reverse proxy that terminates TLS and forwards plain HTTP to
Kino (`docs/guides/deploying.md` §3's documented production topology), this
needs the proxy to set `X-Forwarded-Proto` and Rack to normalize it into
`rack.url_scheme` — confirm that's already true of the deployment setups
`docs/guides/deploying.md` documents before relying on this, since a
misconfigured proxy would silently downgrade production cookies to
non-`Secure` instead of the other way around. That check is the main
reason this is being filed rather than fixed inline: it changes
security-relevant behavior and deserves review of the production path,
not just the dev-over-HTTP case this bug report is about.

## Not done in this doc

No code changed here. This is a bug report + proposed fix for a future
patch release, written up from `monk_talk`'s manual testing rather than
implemented immediately.
