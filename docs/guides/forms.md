# Forms

A Monk form is a plain HTML `<form>`: no form builder, no JavaScript. Monk
reads its body into `params`, refuses one posted from another site, and
lets a route answer a failed submit with the page again and a `422`. With
auth, one helper writes the CSRF field. Everything else is HTML you write.

## A form end to end

```ruby
class App
  get("/notes/new") { @title = "New note"; render "notes/new" }

  post("/notes") do
    require_csrf! # with auth; see "CSRF tokens" below
    @title = "New note"
    body = params[:body].to_s.strip
    if body.empty?
      @error = "Write something first."
      halt(422, render("notes/new"))
    end

    Note.create(body: body)
    redirect "/notes"
  end
end
```

```erb
<%# app/views/notes/new.erb %>
<% if @error %><p role="alert"><%= @error %></p><% end %>
<form method="post" action="/notes">
  <%= csrf_field %>
  <label>Note <textarea name="body" required><%= params[:body] %></textarea></label>
  <button>Save</button>
</form>
```

Without auth, leave out `require_csrf!` and `csrf_field`: the
cross-site check below still covers the form.

- **A failed submit** renders the same page with the status that says why:
  `halt(422, render("notes/new"))`, or `self.status = 422` before a
  `render` the route returns. What the person typed comes back from
  `params`, escaped like everything `<%= %>` prints.
- **A successful submit redirects** (`302`), so reloading the next page
  doesn't post the form again. To say it worked:
  `redirect "/notes", flash: "Saved."` (see "Flash" below).
- **A checkbox left unchecked sends nothing**: `params[:remember]` is `nil`,
  not `"0"`.

The scaffolded login page (`monk add auth`, `app/views/auth/login.erb`) is
a working example.

## Params

A form body (`application/x-www-form-urlencoded`, what a browser sends by
default) and the query string are read the same way:

| Sent | `params` |
|---|---|
| `name=Ann` | `{name: "Ann"}` |
| `user[name]=Ann&user[city]=Rome` | `{user: {name: "Ann", city: "Rome"}}` |
| `tags[]=a&tags[]=b` | `{tags: ["a", "b"]}` |
| `name=Ann&name=Bob` | `{name: "Bob"}`: the last one |

Keys are symbols and values are strings. Arrays of hashes
(`items[][name]`) aren't supported; split the form, or send JSON.

`params` merges the query string, then the body (a form or a JSON object),
then the route's path params, each winning over the one before.

What Monk refuses before the route runs:

| Status | When |
|---|---|
| `400` | A key used both as a value and as a hash (`a=1&a[b]=2`), more than 1,000 params, nesting deeper than 8, malformed JSON, or a JSON body that isn't an object |
| `413` | A form or JSON body over 1 MB (`Monk::Base::MAX_PARSED_BODY`). Kino, the server, refuses any body over 50 MB the same way. |
| `415` | A `multipart/form-data` body: see "Files" below |
| `403` | A request from another site: see the next section |

## Requests from another site

A page on another site can make a browser post to your app, with the
person's cookies attached. Monk refuses these on every route, with or
without auth: a `POST`, `PUT`, `PATCH` or `DELETE` whose `Sec-Fetch-Site`
header says `cross-site` or `same-site` gets a `403`. Every current
browser sends that header; for older ones Monk compares `Origin` with
`Host` instead. A request with neither header isn't from a browser (curl,
another server) and passes.

A route that must accept another site's requests says so:

```ruby
post("/webhooks/payments", allow_cross_origin: true) { ... }
```

A webhook posted by another company's server usually passes anyway, since
it's no browser; the opt-out is for the ones that look like one.

## CSRF tokens (with auth)

With `monk add auth`, a cookie-authenticated route that changes state also
calls `require_csrf!`, as defence in depth behind the check above. It takes
the token from either place:

- **A form**: `<%= csrf_field %>` writes
  `<input type="hidden" name="csrf_token" value="...">` (nothing without a
  session).
- **`fetch`**: the `x-csrf-token` header, set to the `csrf_token` cookie's
  value.

Bearer-authenticated requests skip it: another site can't set that header.

## Flash

A message for the page after a redirect:

```ruby
redirect "/notes", flash: "Saved."
```

The next page reads it with `flash`, a String or `nil`. The scaffolded
layout already shows it on every page:

```erb
<% if flash %><p role="status"><%= flash %></p><% end %>
```

It rides in a cookie (`flash`, `HttpOnly`, `SameSite=Lax`, `Secure` but in
development) for a minute at most. Reading it uses it up, so a reload
doesn't show it again; a page that doesn't read it leaves it for the next
one that does. One message, plain text: keep it short (a cookie holds
about 4 KB). A failed submit doesn't need it: it renders the page again
with its own `@error`.

## Redirects

`redirect` goes only to this app: a path (`/notes`, `notes/1`) or an
`http(s)` URL on the request's `Host`. Anything else raises
`Monk::UnsafeRedirectError`, so `redirect(params[:return_to])` can't
send someone to a lookalike site. Tabs, newlines, spaces and backslashes
are refused too, since browsers read `/\evil.example` as
`//evil.example`. For a location the app built itself on another host,
such as a file's signed link:

```ruby
redirect Monk::Storage.url(key), allow_other_host: true
```

To send a bad `return_to` home instead of raising:

```ruby
error(Monk::UnsafeRedirectError) { redirect "/" }
```

## Verbs other than POST

A form can only send `GET` and `POST`. A `_method` field of `patch`, `put`
or `delete` in a posted form sends it to that verb's route:

```erb
<form method="post" action="/notes/<%= note[:id] %>">
  <%= csrf_field %>
  <input type="hidden" name="_method" value="delete">
  <button>Delete</button>
</form>
```

Only from a form body: never from the query string, a JSON body, or a
`GET`.

## Files

Monk doesn't read `multipart/form-data`: files go from the browser straight
to the bucket through a signed link (`Monk::Storage`, `docs/guides/storage.md`),
so no worker waits on the bytes. A form with a file and other fields
uploads the file first, with the few lines of JavaScript in the storage
guide, puts the key it gets back in a hidden field, and then posts the form
as usual.

## Response headers

Every response carries three headers, under the app's own:

| Header | Why |
|---|---|
| `x-content-type-options: nosniff` | A browser never runs an upload or a JSON body as a script or a stylesheet. |
| `content-security-policy: frame-ancestors 'none'` | No other site can show your pages in a frame and trick a click on a form. |
| `referrer-policy: strict-origin-when-cross-origin` | A link to another site sends only your origin, never a path or a token in it. |

A route replaces one by setting it: `headers["content-security-policy"] =
"frame-ancestors https://partner.example"`. An app with its own
`content-security-policy` should keep a `frame-ancestors` in it.
