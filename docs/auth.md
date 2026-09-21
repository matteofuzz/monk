# Auth & sessions — `Monk::Auth`

Passwordless token auth, opt-in (`require "monk"` never loads it) and built
on `Monk::Persistence::Pg` — not just an integration, a hard dependency:
`Monk::Auth::LoginToken`/`Session` are themselves `Pg::Model` subclasses, so
`require "monk/auth"` always needs the `pg` gem and a registered Postgres
connection, whether or not your app uses persistence for anything else.
`monk new my_app --auth` scaffolds all of it in one step (implying
`--postgres`): `config/auth.rb` and a migration creating the tables below —
see [`scaffolding.md`](scaffolding.md).

```ruby
require "monk/auth"

Monk::Auth.configure(
  db_name: :main, secret: ENV.fetch("AUTH_SECRET"),
  login_ttl: 600, session_ttl: 1_209_600, redirect_allowlist: ["/dashboard"],
)

class App < Monk::Base
  post("/auth/request") { json(token: Monk::Auth.request_login(params[:email])) } # email this token yourself -- Monk doesn't

  get("/auth/callback/:token") do
    session = Monk::Auth.redeem(params[:token])
    halt(401) unless session
    json(token: session[:token], expires_at: session[:expires_at])
  end

  get("/me") { json(subject: require_user!) } # halts 401 automatically if unauthenticated
end
```

Two Postgres tables back this — `login_tokens` (single-use, short-lived)
and `sessions` (multi-use, long-lived). `monk new --auth` scaffolds a
migration for both; otherwise create them yourself the same way persistence
tables aren't generated either — schema in [`auth-sessions.md`](auth-sessions.md).

Both an `Authorization: Bearer <token>` header and a `session_token`
cookie work identically via `current_subject`/`require_user!`. For
browsers, `set_session_cookie(session)` sets that cookie (plus a readable
`csrf_token` one) instead of returning the token as JSON, and
`require_csrf!` guards state-changing routes — a no-op for Bearer
requests, since a forged cross-origin request has no way to set that
header. `Monk::Auth.revoke(token)` / `.revoke_all(subject)` invalidate
sessions; `.sweep!` deletes expired rows. Full design and phase-by-phase
build: [`auth-sessions.md`](auth-sessions.md) / `PLAN-AUTH.md`.
