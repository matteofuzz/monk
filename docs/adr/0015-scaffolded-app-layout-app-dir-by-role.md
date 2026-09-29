# A scaffolded app keeps its own code under `app/`, in directories named by role, and names Monk modules only in `config/`

`monk new` used to put `class App` and every route in `config.ru`, and the app's jobs and templates in top-level `jobs/` and `views/`, next to `bin/`, `db/` and `public/`. The app's own code had no single home, and there was no place for models or anything else. The generated SETUP.md even told users to move `App` out of `config.ru` before they could test it. An app built from the scaffold (monk_talk) ended up with its own `lib/monk_talk/`, where models sat next to a mailer, a module pushing Live updates, and a module getting data ready for pages. We decided how a scaffolded app is laid out, and where code goes that the scaffold doesn't create (`docs/history/plan-app-layout.md`).

```
config.ru              # require_relative "config/load"; require_relative "app/app"; run Monk.boot(App)
config/
  load.rb              # every enabled module's config, then app/ in a fixed order
  settings.rb persistence.rb auth.rb mail.rb jobs.rb live.rb
app/
  app.rb               # class App < Monk::Base and its routes
  models/              # the app's data and the rules on it
  presenters/          # data made ready for a page or partial
  helpers/             # methods every route and template can call (Monk::Context mixins)
  mailers/             # the emails the app sends
  broadcasts/          # what the app pushes to open pages with Monk::Live
  jobs/                # work run later, by bin/jobs
  views/               # .erb templates, the one Monk::Views root
    layouts/  mail/  live/
db/migrate/  public/  bin/  test/
```

**The app's code lives under `app/`, and everything else stays at the top level.** `app/` holds what the developer writes and changes every day. `bin/`, `config/`, `db/`, `public/` and `test/` hold what runs, configures, stores, serves and checks that code. It's the split Rails and Hanami users already expect.

**Directories under `app/` are named by role, not by Monk module.** Most Monk modules have no app code of their own. Auth is config, a migration and one mail template. Mail is config and templates. Live is config and partials. `app/auth/` or `app/mail/` would be nearly empty, and what they held would really be views. `Monk::Views` compiles one root at boot (ADR 0004), so templates must stay in one tree anyway. A feature an app adds (say, contacts) is a model, routes, views, maybe a broadcast and a job. Directories named after modules would scatter it across all of them.

**A role is what the rest of the app calls the code for.** Each role is one plural directory, and it holds whatever does that job, whatever its base class:

| Role | The rest of the app calls it to | monk_talk |
|---|---|---|
| `models/` | read and change the app's data, and apply the rules on it | `Message` (a `Pg::Model`), `Person` (a `Data` with queries), `Contacts`, `ActiveUsers`, `LoginRequests` (modules of SQL) |
| `presenters/` | get data ready for a page or partial, from models | `Panes` |
| `helpers/` | call a method directly from any route or template: modules the app mixes into `Monk::Context` with `Monk::Context.include`, as `Monk::Auth::Helpers` and `Monk::Live::Helpers` do | none yet |
| `mailers/` | send an email: subject, text, and a `views/mail/` template | `Mailer` |
| `broadcasts/` | push a change to open pages (`Monk::Live.patch`/`batch`) | `Delivery` |
| `jobs/` | run work later, in `bin/jobs` (`Monk::Job` subclasses) | `SendLoginLink` |
| `views/` | render HTML (`.erb` only) | every template |

Routes stay in `app/app.rb`. The names come from Rails where it has one (`models`, `mailers`, `presenters`, `helpers`, `jobs`, `views`), and from Turbo for `broadcasts`. We didn't use `patches`, because Patch already means a single DOM operation in `CONTEXT.md`.

**The scaffold always creates every role directory, whatever the flags.** Each ships with a `.keep`, so git keeps it while it's empty. A new app's `app/` is this table: a user sees where each kind of code goes without reading the guide, and never has to decide whether a directory should exist. Flags add files next to the `.keep`s (`--auth` a mailer, `--jobs` a demo job), never directories. `jobs/`, `mailers/` and `broadcasts/` exist even when their module is off. A file added there fails at load with `uninitialized constant Monk::Job` (or `Monk::Mail`, `Monk::Live`) until the module is enabled, which is an immediate and clear error. `models/`, `presenters/` and `helpers/` need no module at all. An app that doesn't want a directory deletes it, and `load.rb` skips it. Code that fits none of these gets a new role, named the same way and added to the guide. Catch-all directories (`services/`, `utils/`) aren't used, because they don't say what the code is for. `helpers/` isn't one of them only because it's defined narrowly: a module there is included into `Monk::Context`, and anything else, however small or general, goes by its role. A presenter and a helper can both prepare things for templates, but a route calls a presenter by name (`Panes.left(...)`), while a helper is part of every request's Context and is called directly. Code that isn't specific to the app at all goes in `lib/`.

**Templates stay in `views/`, grouped by what renders them.** `views/mail/` is rendered by mailers, `views/live/` (or any partials folder) by broadcasts and pages. `.rb` files don't go in `views/`, and `.erb` files don't go anywhere else.

**Monk module names appear only in `config/`, one file per enabled module.** That is where the app says which modules it uses, so the framework's names belong there. It was already the case, and it stays.

**Everything is loaded before the app freezes, in a fixed order, and nothing is autoloaded.** Routes, templates and the `Monk::Context` class with its helper mixins (Monk's and the app's) are sealed at `.freeze!` into Ractor-shareable structures (ADR 0003), so constants can't be resolved lazily from a worker Ractor. `config/load.rb` first requires every enabled config, then each role directory in order: `models`, `presenters`, `helpers`, `mailers`, `broadcasts`, `jobs`. Each directory is loaded as a sorted glob. The order follows who calls whom: presenters read models, helpers and mailers and broadcasts use both, and jobs call all of them. The order matters less than it looks: a constant inside a method is looked up when the method runs, after everything is loaded, so a file's methods may use code from any role, including one loaded after it. That is what lets a model's method enqueue a job, or a mailer be loaded after the models it reads. Only code that runs while the file loads needs what it uses loaded first: a superclass, a constant used in a class body, a `Monk::Context.include`. Such a file uses `require_relative` on the file it depends on, and requiring a file twice is harmless. `config.ru` and `test/test_helper.rb` require `config/load` and then `app/app`. `bin/jobs` and `bin/console` require `config/load`, since jobs and the console use models and mailers. `bin/websocket_server` keeps requiring only the configs it needs, so it still boots without `MAIL_URL`. `app/app.rb` isn't in `load.rb`, so `bin/jobs` doesn't define routes or start the app's `StateRactor`s.

**The file that loads everything is `config/load.rb`, not `config/boot.rb`.** Boot is already a Monk term (`CONTEXT.md`): the step `Monk.boot(App)` triggers, which freezes the app. `config/load.rb` does the work before Boot and never freezes anything, so `config.ru` reads in order: `require_relative "config/load"`, then `run Monk.boot(App)`. `bin/jobs` and `bin/console` load the app's code but never boot it, and the name says so.

**Module configs don't load app code by folder.** Each config configures its module and nothing else. In 0.18 the scaffold's `config/jobs.rb` loaded `jobs/*.rb` itself. From 0.19 it doesn't, since `load.rb` loads `app/jobs/`.

**A config that needs app code requires the specific files it needs.** Configs load before `app/`, and some are also loaded without `load.rb` (by `bin/websocket_server`), so they can't rely on `load.rb` having run. Two cases so far:

- `config/auth.rb` passes the magic-link sender to `Monk::Auth.configure(deliver:)`, which checks its shareability at configure time. So `config/auth.rb` does `require_relative "../app/mailers/app_mailer"`. The mailer only uses `Monk::Mail` when it's called, so `bin/websocket_server`, which loads `config/auth.rb` but not `config/mail.rb`, still works.
- monk_talk's `config/live.rb` has a subscription rule that calls `Person.key`, so it requires `app/models/person`. `bin/websocket_server` then loads that one model, without the rest of `app/`. The scaffold's own `config/live.rb` needs no app code.

**Monk itself doesn't change.** `views` and `assets` stay relative to the working directory (`views "app/views"`), and Monk has no opinion on where an app's files live. This is a scaffold and guide convention, not a framework rule. Existing apps keep working unchanged and can move to it by hand.

## Considered Options

- **Directories named after Monk modules (`auth/`, `live/`, `mail/`, `jobs/`)** (rejected: most would be empty or hold only templates, templates must share one `Monk::Views` root, and an app's own features cut across modules)
- **`models/` only for `Pg::Model` subclasses, other code elsewhere** (rejected: monk_talk's `Person` is a `Data` and `Contacts` a module of SQL, and they do the same job as `Message`; the base class is how a model is built, not what it's for)
- **A catch-all `services/` for everything that isn't a model, job or view** (rejected: it would have held `Mailer`, `Delivery` and `Panes`, three different jobs under one name that says nothing about them)
- **Creating only the role directories the chosen flags have files for** (rejected: the tree then hides the roles an app hasn't used yet, so users have to find them in the guide and decide when to create them, and the scaffold needs a rule per flag; `rails new` also creates every directory)
- **Role directories at the top level (`models/`, `jobs/`, `views/` next to `bin/` and `db/`)** (rejected: flatter at first, but the app's code and its infrastructure stay mixed, and the mix grows with every directory added)
- **Grouping by the app's features (`app/contacts/{model,routes,views}`)** (not taken: works for large apps, but a new app has no features yet, and it would need several view roots or a naming rule inside the one root; an app can still do this inside `app/`)
- **Each module's config loads its own `app/` directory** (`config/persistence.rb` loads models, `config/jobs.rb` loads jobs, as `config/jobs.rb` did) (rejected: roles don't map to modules, since presenters have no config and jobs call mailers, so the load order would depend on the order of configs)
- **`config/boot.rb`** (rejected: clashes with Boot, the freeze step `Monk.boot` triggers, on the first line of `config.ru`; Rails' own `boot.rb` only sets up Bundler anyway)
- **`config/environment.rb`**, the Rails name for this job (rejected: clashes with `MONK_ENV`/`Monk.env`)
- **`config/app.rb`** (rejected: a second `app.rb` next to `app/app.rb`)
- **Autoloading `app/` (Zeitwerk or `autoload`)** (rejected: resolving constants lazily doesn't fit freezing everything at boot, and a sorted eager `require` is a few lines)
- **Keeping the magic-link sender inline in `config/auth.rb`** (not taken: fine for one email, but the second one (monk_talk's invitation) needs a mailer anyway, and a config file then holds app code)
- **Routes split into `app/routes/*.rb` from the start** (not taken: reopening `class App` in more files works before `.freeze!`, and an app can do it whenever it wants to, but a new app has a handful of routes, and one `app/app.rb` is easier to read)
- **`views` resolved relative to `app/app.rb` (`File.expand_path("views", __dir__)`)** (not taken: sturdier when the process starts elsewhere, but every `bin/` script already `cd`s to the app root or uses `__dir__`, and `assets "public"` would then differ in style; can change separately)
