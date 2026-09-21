# Views — HTML with ERB

Templates live in `views/` (by convention; `views "app/views"` moves them)
and are compiled **once at boot**, in the main Ractor, into ordinary
methods — never at request time. That's not a performance preference, it's
what Ractor-safety leaves available: a worker can't hold a template cache
or install methods on a shared module. It also means a template with a
syntax error fails `Monk.boot`, naming the file and line, instead of
blowing up on a live request. See [`views.md`](views.md) for the full design.

```ruby
class App < Monk::Base
  views  "views"          # default
  layout "layouts/app"    # optional default layout
  assets "public"         # default; `assets false` turns static serving off

  get("/") { @title = "Home"; render "index", posts: Post.where(published: true) }
end
```

```erb
<%# views/layouts/app.erb %>
<!doctype html>
<html>
  <head>
    <title><%= @title %></title>
    <link rel="stylesheet" href="<%= asset_path "/css/app.css" %>">
    <script type="module" src="<%= asset_path "/js/app.js" %>"></script>
  </head>
  <body><%= yield %></body>
</html>
```

```erb
<%# views/index.erb %>
<h1><%= @title %></h1>
<ul>
  <% locals[:posts].each do |post| -%>
    <%= render "posts/row", post: post -%>
  <% end -%>
</ul>
```

`render` **returns** the HTML rather than throwing the way `json` and
`halt` do — that's what makes a partial work: a template rendering another
template is the same call. A route block's return value is already the
response body, so `get("/") { render "index" }` needs nothing else, and
`content-type: text/html; charset=utf-8` is set for you.

**`<%= %>` HTML-escapes by default.** This is a deliberate break from stock
ERB, where it doesn't; `<%= raw(html) %>` opts out for a fragment you know
is safe, and `h(value)` escapes explicitly without escaping twice.

**Data reaches a template two ways, neither of which is machinery.** Ivars
set in the route (`@title`) are visible in the template *and* the layout,
because the route block, the template and the layout all execute with
`self` bound to the same `Context`. The `locals` hash passed to `render` is
the other, and it's what a partial rendered inside a loop wants. There's no
locals declaration syntax and no strict-locals checking — a local you
didn't pass reads as `nil`.

Layouts are just Ruby's `yield`: a compiled template is a real method, so
`<%= yield %>` in a layout receives the page's HTML. The default layout
wraps the outermost `render` of a request only, so partials aren't wrapped
again; `render "x", layout: false` skips it and `layout: "layouts/print"`
swaps it.

There is no JavaScript build step, and there won't be one — no bundler, no
transpiler, no `node_modules`. Use `<script type="module">`, relative
imports with real extensions between your own files, and an import map in
the layout for bare specifiers. An app that needs a bundler should run one
itself and drop the output into `public/`.

# Static assets

`public/` is walked at boot into a frozen manifest (body, content-type,
ETag) that worker Ractors read by reference. Assets are looked up **before**
routes, for `GET`/`HEAD` only — the position `Rack::Static` would occupy in
front of the app, so a catch-all splat route can't shadow a stylesheet. The
tradeoff: a route can't override a path that exists as a file.

Responses carry an `ETag` and answer `if-none-match` with a `304`.
`asset_path("/css/app.css")` stamps the URL with a content digest in
production, and a request carrying that stamp is served
`cache-control: public, max-age=31536000, immutable`; everything else gets
`must-revalidate`. No digested filenames, no build manifest.

In production a lookup is an exact-match fetch of a path enumerated at
boot, which makes path traversal structurally impossible rather than
defended against. In development (`MONK_ENV != "production"`) the body is
re-read from disk per request instead, so an edited `.css` or `.js` shows
up on the next refresh with no restart — and `asset_path` doesn't stamp,
since a boot-time digest would go stale the moment you save.

Putting nginx or a CDN in front of Monk is still the right call in
production; this exists so an app is complete on its own.
