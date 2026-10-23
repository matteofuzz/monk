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

## Examples

Commented examples are tagged `# monk:example <name>` ... `# monk:end`.
`grep -rn "monk:example" app config` lists them; uncomment one and adapt it.

## Modules
