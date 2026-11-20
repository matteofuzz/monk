# Forms

A Monk form is a plain HTML `<form>`: no form builder, no JavaScript. Monk
reads its body into `params`, refuses one posted from another site, and
lets a route answer a failed submit with the page again and a `422`. With
auth, one helper writes the CSRF field (`csrf_field`). Everything else is
HTML you write.

There are no form helpers, by choice: a field is the HTML a browser
reads, and every person and agent already knows it. The patterns below
cover what a builder would do.

## A simple form: logging in

```ruby
class App
  get("/login") { @title = "Log in"; render "login" }

  post("/login") do
    @title = "Log in"
    user = User.authenticate(params[:email], params[:password]) # the app's own check
    redirect "/", flash: "Welcome back." if user

    @error = "Wrong email or password."
    halt(422, render("login"))
  end
end
```

```erb
<%# app/views/login.erb %>
<h1>Log in</h1>

<% if @error %><p role="alert"><%= @error %></p><% end %>

<form method="post" action="/login">
  <label>
    Email
    <input type="email" name="email" value="<%= params[:email] %>" required autocomplete="email">
  </label>
  <label>
    Password
    <input type="password" name="password" required autocomplete="current-password">
  </label>
  <label>
    <input type="checkbox" name="remember" value="1" <%= "checked" if params[:remember] %>>
    Keep me logged in
  </label>
  <button>Log in</button>
</form>
```

- **A failed submit** renders the same page with the status that says why:
  `halt(422, render("login"))`, or `self.status = 422` before a `render`
  the route returns. What the person typed comes back from `params`,
  escaped like everything `<%= %>` prints. The password field is never
  filled back.
- **A successful submit redirects** (`302`), so reloading the next page
  doesn't post the form again, and `flash:` says it worked (see "Flash").

(Monk's own auth logs in by email link; `monk add auth` scaffolds that
page, `app/views/auth/login.erb`, as a plain form too.)

## A bigger form: new and edit

An event with text, a date, a number, a select, radio buttons and a
checkbox, created and edited through one partial.

```ruby
# app/models/event.rb
class Event < Monk::Persistence::Pg::Model
  self.db_name = :primary
  self.table_name = "events"

  CATEGORIES = Ractor.make_shareable({ "talk" => "Talk", "workshop" => "Workshop", "meetup" => "Meetup" })

  # The row to store, built field by field from the form: never pass
  # params to create/update as they are, or the form picks the columns.
  def self.from_form(form)
    {
      title: form[:title].to_s.strip,
      description: form[:description].to_s,
      date: form[:date].to_s,
      seats: form[:seats].to_s.empty? ? nil : form[:seats].to_i,
      category: form[:category].to_s,
      visibility: form[:visibility] == "members" ? "members" : "public",
      online: form[:online] == "1",
    }
  end

  # Field => message; empty when the row can be stored.
  def self.errors_for(row)
    errors = {}
    errors[:title] = "can't be empty" if row[:title].empty?
    errors[:date] = "must be in the future" if row[:date] <= Time.now.strftime("%F")
    errors[:category] = "choose one" unless CATEGORIES.key?(row[:category])
    errors[:seats] = "between 1 and 500" if row[:seats] && !(1..500).cover?(row[:seats])
    errors
  end
end
```

```ruby
# app/routes/events.rb
class App
  get("/events/new") { @event = {}; @errors = {}; render "events/new" }

  post("/events") do
    require_csrf!
    @event = params[:event] || {}
    row = Event.from_form(@event)
    @errors = Event.errors_for(row)
    halt(422, render("events/new")) if @errors.any?

    event = Event.create(row)
    redirect "/events/#{event[:id]}", flash: "Event created."
  end

  get("/events/:id/edit") do
    @event = Event.find(params[:id]) || halt(404)
    @errors = {}
    render "events/edit"
  end

  patch("/events/:id") do
    require_csrf!
    @event = (params[:event] || {}).merge(id: params[:id])
    row = Event.from_form(@event)
    @errors = Event.errors_for(row)
    halt(422, render("events/edit")) if @errors.any?

    Event.update(params[:id], row)
    redirect "/events/#{params[:id]}", flash: "Saved."
  end
end
```

`events/new.erb` and `events/edit.erb` are a heading and
`<%= render "events/_form" %>`. The partial reads `@event`, which is the
record when editing and `params[:event]` after a failed submit: both are
hashes with symbol keys.

```erb
<%# app/views/events/_form.erb %>
<% e = @event %>
<% if @errors.any? %><p role="alert">Please fix the fields marked below.</p><% end %>

<form method="post" action="<%= e[:id] ? "/events/#{e[:id]}" : "/events" %>">
  <%= csrf_field %>
  <% if e[:id] %><input type="hidden" name="_method" value="patch"><% end %>

  <label>
    Title
    <input name="event[title]" value="<%= e[:title] %>" required>
  </label>
  <%= render "_error", message: @errors[:title] %>

  <label>
    Description
    <textarea name="event[description]" rows="4"><%= e[:description] %></textarea>
  </label>

  <label>Date <input type="date" name="event[date]" value="<%= e[:date] %>" required></label>
  <%= render "_error", message: @errors[:date] %>

  <label>Seats <input type="number" name="event[seats]" value="<%= e[:seats] %>" min="1" max="500"></label>
  <%= render "_error", message: @errors[:seats] %>

  <label>
    Category
    <select name="event[category]">
      <option value="">Choose one</option>
      <% Event::CATEGORIES.each do |value, label| %>
        <option value="<%= value %>" <%= "selected" if e[:category] == value %>><%= label %></option>
      <% end %>
    </select>
  </label>
  <%= render "_error", message: @errors[:category] %>

  <fieldset>
    <legend>Visibility</legend>
    <% { "public" => "Anyone", "members" => "Members only" }.each do |value, label| %>
      <label>
        <input type="radio" name="event[visibility]" value="<%= value %>"
               <%= "checked" if (e[:visibility] || "public") == value %>>
        <%= label %>
      </label>
    <% end %>
  </fieldset>

  <label>
    <input type="hidden" name="event[online]" value="0">
    <input type="checkbox" name="event[online]" value="1" <%= "checked" if [true, "1"].include?(e[:online]) %>>
    Online event
  </label>

  <button><%= e[:id] ? "Save" : "Create event" %></button>
</form>
```

```erb
<%# app/views/_error.erb: a field's message, or nothing %>
<% if locals[:message] %><small class="error"><%= locals[:message] %></small><% end %>
```

## Patterns

- **Filling a field back**: `value="<%= e[:title] %>"`, or the text
  between `<textarea>` tags. Escaped like everything `<%= %>` prints.
- **A select, a radio button**: compare each option's value with the
  current one, `<%= "selected" if e[:category] == value %>` (`checked`
  for a radio). A default is `(e[:visibility] || "public") == value`.
- **A select with several choices**: name it with `[]`, so the choices
  arrive as an Array:

  ```erb
  <select name="event[tags][]" multiple>
    <% TAGS.each do |tag| %>
      <option <%= "selected" if Array(e[:tags]).include?(tag) %>><%= tag %></option>
    <% end %>
  </select>
  ```
- **A checkbox** sends nothing when unchecked. Put a hidden `0` before
  it with the same name: unchecked, the `0` arrives; checked, the `1`
  after it wins (a repeated name keeps the last value). A record holds
  `true`, the form `"1"`: `[true, "1"].include?(e[:online])` reads both.
- **Errors**: a Hash of field => message, built by a plain method
  (`Event.errors_for`), shown next to each field by a two-line partial.
- **One partial for new and edit**: the record has an `:id`, a new one
  doesn't; the form's `action`, its `_method` and its button follow.
- **From form to row**: build the row field by field (`Event.from_form`),
  converting types there (`""` to `nil`, `"1"` to `true`). Never pass
  `params` straight to `create`/`update`: the form would choose the
  columns.
- **Without auth**, leave out `require_csrf!` and `csrf_field`: the
  cross-site check still covers the form.

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
