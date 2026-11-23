# {{app}}: notes for coding agents

A Monk app (Ruby, Ractor-based). Read this before changing code.

## Commands

- `bin/server`: the app on :9292.
- `bundle exec rake test`: all tests. Run them after every change.
- `monk add --list --json`: the modules available, and which are installed.
- `monk add <module> --json`: add a module. Never wire one by hand in
  `config/load.rb`: it loads every module's config already.

## Where code goes

| Path | What |
|---|---|
| `app/app.rb` | `class App`, its base routes; loads `app/routes/*.rb` |
| `app/routes/<name>.rb` | more routes, each file reopening `class App` |
| `app/models/` `presenters/` `helpers/` `mailers/` `broadcasts/` `jobs/` | code by role, loaded in that order by `config/load.rb` |
| `app/views/` | `.erb` templates only, the one template root |
| `config/<module>.rb` | one per Monk module, loaded by `config/load.rb` in a fixed order |
| `test/` | Minitest; `test/test_helper.rb` boots the app as `APP` |

## Rules that break the app if ignored

- Everything loads before `Monk.boot` freezes the app. Nothing can be
  required later, from a route or a job.
- Routes, jobs and Live rules run in Ractors. A block they use must be
  Ractor-shareable: define it inside a module or class body, never at the
  top level of a file (`self` there is the main object).
- State shared across requests lives in a `Monk::StateRactor`, never in a
  constant or a class variable.
- Templates escape what they print. `raw(...)` is only for HTML the app
  built itself.
- A browser request from another site to any route but a GET gets a 403.
  A route that must take one (a webhook) declares
  `allow_cross_origin: true`.
- `redirect` goes only to this app (a path, or a URL on this host) and
  raises otherwise; `allow_other_host: true` only for a URL the app built.

## Forms

Plain HTML forms, no form helpers: write the `<input>`s.

- `params` reads form bodies and query strings: `a[b]=1` is
  `{a: {b: "1"}}`, `a[]=1&a[]=2` is `{a: ["1", "2"]}`, keys are symbols,
  values strings. No arrays of hashes (`a[][b]`). Path params win.
- Failed submit: set the errors, then `halt(422, render("x/new"))`; the
  form fills back from `params`. Success: `redirect "/x/1", flash: "Saved."`
  (the layout shows `flash`).
- Never pass `params` to `Model.create`/`update`: build the row field by
  field in the model (`from_form`), converting `""` to `nil`, `"1"` to
  `true`. Errors are a Hash field => message from a plain method.
- One partial for new and edit, reading `@event` (the record, or
  `params[:event]` after a failed submit). Edit posts with a hidden
  `<input name="_method" value="patch">`.
- Select/radio: `<%= "selected" if e[:category] == value %>` (`checked`).
  Multiple select: `name="event[tags][]"`. Checkbox: a hidden `0` with
  the same name before it; a record holds `true`, a form `"1"`, so test
  `[true, "1"].include?(e[:online])`.
- No `multipart/form-data` (415): files go through `Monk::Storage`'s
  direct upload, and the form posts the key.

## Examples

Commented examples are tagged `# monk:example <name>` ... `# monk:end`.
`grep -rn "monk:example" app config` lists them; uncomment one and adapt it.

## Modules

Each module added with `monk add` appends its own section below.
