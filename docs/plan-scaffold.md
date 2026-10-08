# Scaffolding by module (`monk new` + `monk add`): implementation plan

Branch: `main_dev/refactor_scaffolding`.
Status: Phases 0–8 implemented on this branch, 2026-10-08 (choices made
along the way are recorded in decisions 9, 14, 21, Phase 2 step 6, Phase 4
and auth). Left: the notes at the top of the scheduled-jobs and storage
plans, on their branches, and Phase 9 (optional). Ergonomics for humans
and agents reviewed on 2026-10-08 (decisions 25–30).
Companion record, to write in Phase 0: `adr/0017-scaffold-by-module-generators.md`
(it amends [`adr/0015`](adr/0015-scaffolded-app-layout-app-dir-by-role.md)
on where routes live).

`monk new` grew one flag per module, and every new flag adds files,
text anchors, whole-file overrides, implied flags, rules for pairs of
flags, and branches in SETUP.md. `lib/monk/scaffold.rb` is about 1060
lines, about 600 of them SETUP.md text. The three descriptions of the
flags (`exe/monk` HELP, `docs/guides/scaffolding.md`, SETUP.md) have
already drifted apart: HELP still talks about `config.ru` wiring and
`views/`/`jobs/` at the top level, which ADR 0015 moved. A flag also only
works when the app is created: an app made without `--jobs` gets jobs
only by hand.

This plan replaces the flags with **one generator per module**, run by
`monk add <module>` on any app, new or existing. `monk new NAME` writes
the bare app, and `monk new NAME --with a,b` is shorthand for that plus
`monk add a b`. Three goals shape every decision:

1. **Each module is added on its own.** A generator creates new files and
   appends lines to the end of a few shared files. It never edits a
   user's file in the middle or replaces one, and it doesn't depend on
   which other modules are present or on the order they were added in.
2. **All wiring is ready.** After `monk add X`, module X runs: config,
   gem, env vars, migration, `bin/` process.
3. **Usage is shown, and the wiring is proved.** Every module comes with
   commented **examples** of the code an app writes to use it, in the
   file where that code belongs, and with a generated **test** that
   proves the wiring works. Only `live` also gets a demo you can see.

## Target layout

```
lib/monk/cli.rb                      # what exe/monk runs: new, add, add --list, help (generated from the generators)
lib/monk/generator.rb                # the DSL and its actions; idempotent, never overwrites
lib/monk/generator/result.rb         # created/appended/skipped/conflicts/next steps; printed as text or --json
lib/monk/generators/base.rb          # what `monk new` writes
lib/monk/generators/postgres.rb
lib/monk/generators/redis.rb
lib/monk/generators/mail.rb
lib/monk/generators/auth.rb
lib/monk/generators/jobs.rb
lib/monk/generators/websocket.rb
lib/monk/generators/live.rb
lib/monk/templates/<module>/...      # files copied verbatim, as today
lib/monk/templates/<module>/setup.md     # the module's SETUP.md section
lib/monk/templates/<module>/agents.md    # the module's AGENTS.md section
test/generator_test.rb               # the engine: actions, idempotency, conflicts, --dry-run, --json
test/generators/<module>_test.rb     # each generator, plus the generated app's own tests passing
test/generators/examples_test.rb     # every `monk:example` block, uncommented, boots and works
test/generators/combinations_test.rb # order independence, adding twice, every combination booting
```

`lib/monk/scaffold.rb`, `test/scaffold_*_test.rb` and the per-flag
overrides under `templates/` are deleted in Phase 7.

## Decisions

These fill in the design agreed in review on 2026-10-07/08. Each can still
change in review.

### What a module adds

1. **Three kinds of code per module.**
   - **Wiring**: config, gem, env vars, migration, `bin/` process. It
     runs as soon as it's added.
   - **Example**: the code the app writes to use the module (routes, a
     rule, a mailer call). It is commented out, in the file where it would
     go, and the app uncomments and changes it.
   - **Proof**: a generated test in `test/`, which `rake test` runs.

   Only `live` also gets a demo you can open in a browser
   (decision 14).
2. **Generators only create files and append lines.** The actions are:
   - copy a new file;
   - append lines to `Gemfile`, `.gitignore`, `.dockerignore` and the
     `.env*` files, skipping any line or env key that's already there;
   - add a timestamped migration;
   - append a marked section to `SETUP.md` and `AGENTS.md`.

   No text anchors, no whole-file overrides. If a file the generator
   would create already exists with different content, that's a
   *conflict*, handled by the file's role (decision 26). An env key
   that's already set keeps the app's value.
3. **Idempotent.** A module counts as installed when its config file
   exists (`config/<module>.rb`; `config/persistence.rb` for `postgres`).
   Adding an installed module again changes nothing and says so. Appended
   sections carry a marker (`<!-- monk:module jobs -->`) so they're never
   added twice.
4. **Dependencies are added first, automatically.** `depends_on`
   declares them: `auth` → `postgres`, `mail`; `jobs` → `postgres`;
   `websocket` → its transport, `postgres` or `redis` (decision 13);
   `live` → `websocket`. `monk add auth` on a bare app adds three modules,
   and the result lists them.
5. **Migrations get the timestamp of when the module is added**
   (`YYYYMMDDHHMMSS_create_jobs_tables`), no longer the fixed
   `00000000000001`/`…02`. The migrator applies every version missing
   from `schema_migrations` (checked in `pg/migrator.rb`), so a module
   added to an older app migrates normally. Monk's own tests keep
   applying the canonical SQL from `templates/`.

### Removing the rules between modules

Every rule that today depends on two flags together moves into the
framework, or into a static file written once.

6. **`config/load.rb` is static.** It holds Monk's module list in its
   fixed order and requires each config that exists:
   ```ruby
   %w[persistence redis auth mail jobs websocket live storage].each do |name|
     path = File.expand_path("#{name}.rb", __dir__)
     require path if File.exist?(path)
   end
   ```
   `wire_load!` and its anchor go away. `auth.rb` already requires
   `persistence` itself, and requiring a file twice is harmless.
7. **Routes live in `app/routes/<module>.rb`.** `app/app.rb` ends with
   one static line loading `app/routes/*.rb` (sorted), each file
   reopening `class App`. ADR 0015 decided against splitting routes
   ("Routes split into `app/routes/*.rb` from the start"). Generators
   are a new reason: the alternative is editing the user's `app/app.rb`.
   ADR 0017 records the change. `bin/jobs` and `bin/console` load
   `config/load`, not `app/app.rb`, so they still don't define routes.
8. **mail + jobs live in the framework, in both directions.**
   `lib/monk/jobs.rb` ends with `require_relative "mail/later" if
   defined?(Monk::Mail)`, and `lib/monk/mail.rb` does the reverse
   (`require "monk/mail/later" if defined?(Monk::Jobs)`). Either load
   order works. `add_deliver_later!` and its anchor go away.
   `JOBS_QUEUES` defaults to `mailers,default` whether or not mail is
   on: a queue with nothing in it costs nothing.
9. **auth + jobs live in the framework.** `SendLoginLink` (today
   `templates/jobs/app/jobs/send_login_link.rb`) becomes
   `Monk::Auth::SendLoginLink`, defined when both modules are loaded, the
   same symmetric way as decision 8. No app file, no pair rule. Its queue,
   attempts and `never_retry` stay as they are (ADR 0014). The job needs
   the callback route's path, which was hard-coded in the app's file, so
   (settled 2026-10-08) `Monk::Auth.configure` gains `callback_path:`
   (default `"/auth/callback"`, an absolute path, any trailing slash
   dropped), and `Monk::Auth.login_link(token)` builds
   `public_url + callback_path + "/" + token`. The job, the commented
   `auth-routes` example and `config/auth.rb` all use it, so the path is
   written once. Considered: keeping the job as an app file (a pair rule
   again), and a `login_link:` lambda in the config (more flexible, but
   one more Ractor-shareability trap, for a need no app has shown).
10. **auth's mailer is its own file.** `app/mailers/auth_mailer.rb`
    (`AuthMailer::MAGIC_LINK`), with `config/auth.rb` requiring it. `mail`
    owns `app/mailers/app_mailer.rb`. The two generators never write the
    same file.
11. **`<%= monk_head %>` in the base layout.** A core `Monk::Context`
    helper renders the `<head>` tags that loaded modules register (a
    small registry, sealed at freeze like the others). `monk/live`
    registers its `<meta name="monk-live-url">` and `<script>`.
    `add_live_to_layout!` goes away. The helper returns trusted HTML,
    the same way `live_topic` does (ADR 0005).
12. **Monk serves Live's browser client from the gem**, at a
    `/_monk/live/` path, the way the storage plan serves
    `/_monk/storage/:token` from `Base#dispatch`. `copy_live_client!` goes
    away, and so does the risk of a copy older than the gem. If
    fingerprinting through `asset_path` makes this awkward, the fallback is
    to keep copying into `public/js/monk_live/`. That is still only new
    files, so goal 1 holds.
13. **Redis is a module of its own; WebSocket is a module that picks a
    transport, and Live reuses it.**
    - **`redis`** is like `postgres`: a service the app may want for its
      own reasons (a cache, rate limits, locks), with or without sockets.
      It adds the gem, `REDIS_URL`, and `config/redis.rb`, which declares
      the `redis_url` setting. It depends on nothing, and nothing depends
      on it unless `redis` is chosen as the transport.
    - **`websocket`** moves `bin/websocket_server` out of the base app.
      HELP's line "WebSocket needs no external service, so it isn't behind
      a flag" stops applying: `bin/server` and `bin/websocket_server` are
      separate processes, so sockets need something to carry messages
      between them.
    - **Its `config/websocket.rb` chooses the transport once**, with
      `--transport=postgres|redis`: `AppWebSocket::REGISTRY` is a
      `PgFanout` or a `RedisFanout` around a `Registry`. The chosen module
      is a dependency (decision 4), so `--transport=redis` on an app
      without Redis adds `redis` first. The config `require_relative`s
      `persistence` or `redis` itself, the way `auth.rb` requires
      `persistence`.
    - **When `--transport` can be left out** (decision 23): if exactly one
      of `postgres` and `redis` is installed, or being added in the same
      command, that one is used. With neither or both, it's a choice the
      user has to make.
    - **`live` has no transport option**: it passes
      `AppWebSocket::REGISTRY` to `Monk::Live.configure(registry:)`, which
      accepts any registry or fanout. An app chooses its transport in one
      place. Changing it later is documented, not a command (settled
      2026-10-08). It takes three steps: `monk add` the other module if
      it isn't installed, change the one line in `config/websocket.rb`,
      and restart both processes. Websocket's AGENTS.md and SETUP.md
      sections and `docs/guides/websocket.md` each show the steps. Every
      generator keeps creating files and appending lines, with none
      rewriting a file.
    - **`bin/websocket_server`** loads `config/websocket.rb`, plus
      `config/auth.rb` and `config/live.rb` only if they exist (today's
      `rescue LoadError`). It calls `listen!` on the registry once. With
      live, it runs Live's handler. Otherwise it runs
      `AppSockets::HANDLER` when `app/sockets/` defines one, with the
      chat handler as a commented example in `app/sockets/chat.rb`. With
      neither, it exits with a message naming both options.
      `LIVE_OVERRIDES` and `LIVE_CONFIG_TEMPLATES` go away.
    - **To check in Phase 4:** a chat handler and Live sharing one registry
      can't collide on topic names (Live's topics are strings, the chat's
      `:chat` a symbol), and `Monk::Live.listen!` plus the server don't
      call the registry's `listen!` twice.

### Proof and examples

14. **Every module gets a generated test, and only `live` gets a
    demo.** A test can't show two browser tabs updating together, and
    that's where live breaks (ports, `WS_ALLOWED_ORIGINS`, `LIVE_WS_URL`).
    The live demo is `app/routes/demo_live.rb` plus
    `app/views/demo/live.erb` and `_hits.erb`, at `/demo/live`, and
    **defined only in development** (`if Monk.env.development?`). It's on
    by default, and `--no-demo` skips it. It never replaces `/` or
    `index.erb`. Its subscribe rule can't live in the demo's route file,
    because `bin/websocket_server` loads `config/live.rb` and never `app/`.
    So (settled 2026-10-08) it's three marked lines in `config/live.rb`,
    under the commented `live-rule` example:
    `# monk:demo live` + `if Monk.env.development?` +
    `Monk::Live.authorize("demo:hits", anonymous: true, &Monk::Live::ALLOW_ALL)`,
    where `ALLOW_ALL` is a shareable allow-everyone proc Monk provides.
    Removing the demo means deleting `app/routes/demo_live.rb`,
    `app/views/demo/` and those lines; left behind, they're a harmless
    development-only rule for a topic nothing publishes. Considered: a
    `config/live_demo.rb` that `config/live.rb` requires if it exists, and
    a built-in development-only `demo:` prefix in Monk.
15. **Examples are tagged blocks.**
    ```ruby
    # monk:example auth-routes -- uncomment, then add your rate limit (see AGENTS.md)
    # post("/auth/request") do
    #   ...
    # end
    # monk:end
    ```
    They can be found with grep, and "enable the auth routes" is a
    well-defined task for a person or an agent.
    `test/generators/examples_test.rb` uncomments every block in a
    generated app, boots it, and makes one request per block, so an
    example can't go stale when an API changes.
16. **Each module's generated test runs in the generated app**, with the
    test setup the base app now ships (decision 18). Monk's suite runs
    those tests the way `scaffold_test.rb` already boots generated apps.

### Base app, SETUP.md and AGENTS.md

17. **Dotenv is always on** in the base Gemfile. `uncomment_dotenv!`
    goes away.
18. **The base app ships its test setup**: minitest and rake in the
    Gemfile's test group, `test/test_helper.rb` (it loads `.env.test` if
    the file exists, then `config/load` and `app/app`, then
    `APP = Monk.boot(App)`), `Rakefile`, `test/app_test.rb`. Half of
    today's SETUP.md explains how to set these up, and that text goes
    away.
19. **SETUP.md is a base part plus one section per module**, each written
    for that module alone: no "if you also have X". The conditional
    builders in `scaffold.rb` go away.
20. **`AGENTS.md` and a `CLAUDE.md` that imports it (`@AGENTS.md`).** The
    base section covers:
    - the layout (ADR 0015's table);
    - commands (`bin/server`, `rake test`, `monk add --list`);
    - the rules an agent most often gets wrong: code that runs in a
      Ractor must be shareable, so its blocks go in a module; everything
      loads before boot and nothing loads later; templates live in
      `app/views/`.

    It also says to run `rake test` after every change and to add
    modules with `monk add`, never by editing `config/load.rb`.

    Each module adds a section under `## Modules`, marked
    `<!-- monk:module <name> -->`, always with the same headings:
    **Where** (its files), **Main calls**, **Test** (its generated
    test), **Pitfalls** (e.g. "never point `deliver:` at
    `deliver_later`", "a per-email rate limit before `/auth/request` goes
    live"), and **Examples** (its tags and files). Content that fits both
    files is split by purpose: SETUP.md is for getting the app running
    once (services, databases, first commands), and AGENTS.md is the
    reference for working on it day to day.
21. **The Dockerfile is no longer replaced.** Either the base Dockerfile
    always installs libpq (a few MB), or the app uses a precompiled
    `pg` gem, if recent `pg` versions ship platform gems that bundle
    libpq. Phase 2 checks the second option first. `POSTGRES_OVERRIDES`
    goes away. Checked 2026-10-08: `pg` 1.6+ ships `x86_64-linux` and
    `aarch64-linux` gems built for Ruby 3.1–4.0 with libpq bundled, and a
    `ruby:4.0-slim` build with no system packages installed `pg` and
    connected to Postgres, even from a lockfile made on macOS only. So
    `monk add postgres` adds `gem "pg", "~> 1.6"`, and the base Dockerfile
    serves every app.

### CLI

22. **Commands.**
    - `monk new NAME [--with a,b] [--no-demo] [--transport=redis|postgres]`
    - `monk add MODULE... [same options]`
    - `monk add --list`: every module, whether it's installed, its
      dependencies, its options
    - `monk help [MODULE]`

    Every command takes `--dry-run` and `--json`. HELP is built from the
    generators' own descriptions, so it can't drift. The name is `add`,
    not `scaffold` or `generate`: `generate` is left free for app code
    later (models, migrations).
23. **Never interactive without a terminal.** The only real choice today
    is websocket's transport, and it's inferred when possible
    (decision 13). Otherwise a terminal gets a prompt, and anything else
    gets an error naming `--transport`, never a prompt waiting for
    input. An interactive `monk new` checklist is optional, last
    (Phase 9).
24. **The old flags are removed, with no transition period.** Every
    module, `postgres` and `redis` included, is added with
    `monk add MODULE`, or with `--with` when the app is created. Monk is
    pre-1.0 and monk_talk is the only app built from the scaffold, so
    `monk new` doesn't translate today's flags. Any of them is a usage
    error that shows the new form of that same command (e.g.
    `--auth --live --redis` → `--with auth,live --transport=redis`), and
    nothing is written. The table below is for our reference while
    writing that message and its tests; it isn't shipped as
    documentation.

    | Today | New |
    |---|---|
    | `monk new app --postgres` | `monk new app --with postgres` |
    | `monk new app --mail` | `monk new app --with mail` |
    | `monk new app --auth` | `monk new app --with auth` (adds postgres and mail) |
    | `monk new app --jobs` | `monk new app --with jobs` (adds postgres) |
    | `monk new app --redis` | `monk new app --with redis` |
    | `monk new app --live --postgres` | `monk new app --with live --transport=postgres` (adds websocket and postgres) |
    | `monk new app --live --redis` | `monk new app --with live --transport=redis` (adds websocket and redis) |

### What people see (settled in the ergonomics review, 2026-10-08)

25. **`monk add`'s text output**, in this order:
    - **Dependencies first**: "Adding auth, which needs postgres and
      mail — adding those first." (or "postgres already installed").
    - **Files grouped by module**, one line per file or group of
      files: `+` created, `~` appended to (with what was appended:
      `pg, irb`, `DB_*`), `!` not written, with the reason.
    - **Example blocks marked inline**, e.g.
      `app/routes/auth.rb   example: auth-routes (commented)`.
    - **"Set before production"**, listing only placeholders and settings
      with real consequences (`AUTH_SECRET`, `MAIL_URL`), not every env
      var written.
    - **"Next:"**, at most three numbered steps, citing the SETUP.md
      section for anything longer (`start Postgres and create the
      databases   (SETUP.md › postgres)`).
    - At most one closing sentence for the one thing that matters most
      (enable `auth-routes` and add a rate limit; remove the live demo
      when done).

    Adding an installed module prints one line ("jobs is already
    installed — nothing to do."). `--dry-run` prints the same list
    under "Would add …" and writes nothing. The transport question
    gives one line of trade-off per option and names the flag that skips
    it. Every error ends with "Nothing was written."
26. **Conflicts depend on the file's role**, which each generator
    declares for every file it writes:
    - **wiring**: config, `bin/`, migrations, and any file a config
      requires (e.g. `app/mailers/auth_mailer.rb`). A conflict here
      would leave the app broken, so the command stops before writing
      anything, names the file, and ends with "Nothing was written."
      Every file is checked before any is written.
    - **example, test, view, demo**: the file is left alone and marked
      `!`. The module is still installed, and the output names the
      command that prints Monk's version of the file
      (`monk help storage --file test/storage_test.rb`).

### What agents see (settled in the ergonomics review, 2026-10-08)

27. **`--json` prints one object** with the same content as the text
    output, plus what an agent needs in order to act without reading
    prose:
    ```json
    {
      "status": "ok",
      "written": true,
      "requested": ["auth", "jobs"],
      "modules":  [{"name": "postgres", "action": "added", "reason": "needed by auth, jobs"}],
      "files":    [{"path": "config/auth.rb", "module": "auth", "role": "wiring", "action": "created"},
                   {"path": "Gemfile", "module": "postgres", "action": "appended", "items": ["pg", "irb"]},
                   {"path": "app/routes/auth.rb", "module": "auth", "role": "example", "action": "created",
                    "examples": ["auth-routes"]}],
      "skipped":  [{"path": "test/storage_test.rb", "role": "test", "show": "monk help storage --file test/storage_test.rb"}],
      "env":      [{"key": "AUTH_SECRET", "files": [".env", ".env.test", ".env.example"],
                    "placeholder": true, "required_in": ["staging", "production"]}],
      "examples": [{"tag": "auth-routes", "path": "app/routes/auth.rb", "line": 4,
                    "todo": "uncomment, add a per-email rate limit; use the SendLoginLink variant (jobs is installed)"}],
      "services": [{"name": "postgres", "check": "pg_isready -h 127.0.0.1 -p 5432", "setup": "SETUP.md#postgres"}],
      "next":     [{"run": "bundle install"}, {"run": "bin/setup_db", "needs_service": "postgres"}],
      "docs":     ["AGENTS.md#auth", "SETUP.md#postgres"]
    }
    ```
    - **`status`** is one of `ok`, `usage_error`, `missing_choice` or
      `conflict`.
    - **`written`** says whether anything was written.
    - **Errors** add `message`, and where relevant `suggestion` (the
      command to run instead), `choice` (option, values, reason) or
      `conflicts` (path, role, `show`).
    - **"Already installed"** is `ok` with `written: false` and
      `action: "already_installed"`.
    - **`examples[].todo`** may depend on which modules are installed
      (the `SendLoginLink` variant when jobs is there). That's the one
      place output depends on other modules, and it's text only, never
      a file.
    - **`monk add --list --json`** gives
      `{"modules": [{"name", "installed", "needs", "needs_one_of", "options"}]}`.

    The schema is part of Monk's interface. `test/exe_monk_test.rb`
    pins it, and the CHANGELOG notes any change.
28. **Exit codes.**

    | Code | Meaning | `written` |
    |---|---|---|
    | 0 | done, including "already installed" and "example/test files skipped" (listed in `skipped`) | true or false |
    | 1 | usage error: unknown module, old flags, bad option | false |
    | 2 | a choice is missing (`--transport`) | false |
    | 3 | conflict on a wiring file | false |
29. **External services are declared and checked.** Each generator that
    needs a service declares:
    - a command that checks it's running (`pg_isready …`, `redis-cli
      ping`);
    - its SETUP.md section.

    `services` in the JSON lists them, and each `next` step that needs
    one is marked with it. The scaffold's `bin/` scripts (`setup_db`,
    `migrate`, `console`, `jobs`, `websocket_server`) fail the same way
    `monk` does: what failed, which setting (`DB_HOST`/`DB_PORT in .env`),
    and the exact commands from SETUP.md, with exit code 1. This touches
    scripts that exist today (Phase 2).
30. **Nothing else to keep in sync.** There's no `monk example <tag>`
    command: grep on `monk:example` finds every block, and the JSON
    gives the line numbers. There's no manifest (`monk.yml`): the
    installed modules are their `config/` files, and
    `monk add --list --json` reports them. A manifest would be a second
    source of truth that could drift.

## Module by module

What each generator writes. Every module also appends its SETUP.md and
AGENTS.md sections, and its env lines to `.env`, `.env.test` and
`.env.example` where it has any.

### base (`monk new`)
- Files: today's `BASE_FILES` minus `bin/websocket_server`, plus the
  test setup (decision 18), `AGENTS.md`, `CLAUDE.md`, the static
  `config/load.rb` (decision 6), `app/app.rb` loading `app/routes/`, an
  empty `app/routes/` (`.keep`), and the layout with `monk_head`.
- Example: none beyond the home page and `/hello`/`/api/hello`, which
  stay.
- Proof: `test/app_test.rb` (`GET /hello`).

### postgres
- Wiring: `config/persistence.rb`; `bin/console`, `bin/setup_db`,
  `bin/migrate`; `db/migrate/.keep`; `pg` and `irb` in the Gemfile; `DB_*`
  env vars with `DB_NAME` taken from the app directory, as today.
- Example `postgres-model`, in `app/routes/postgres.rb`: the migration's
  SQL, a short `Pg::Model` for `app/models/`, and a route reading it, all
  in one commented block. A `.sql` file of comments would get applied
  and recorded as a migration, so the SQL can't be a file.
- Proof: `test/persistence_test.rb`, which connects and runs `SELECT 1`.
- Setup: start Postgres, create the two databases, `bin/setup_db`.

### mail
- Wiring: `config/mail.rb`, `net-smtp`, `MAIL_FROM`; `MAIL_URL=log://`
  in `.env.test`.
- Example `mail-welcome`: a commented `WELCOME` in
  `app/mailers/app_mailer.rb`, a real `app/views/mail/welcome.erb` (a
  template nothing renders does no harm), and the call, commented, in
  `app/routes/mail.rb`.
- Proof: `test/mail_test.rb` renders and delivers to `log://`, then checks
  the message.
- Setup: `MAIL_URL`/`MAIL_FROM` outside development, and a link to the
  provider guide.

### auth (pulls in postgres and mail)
- Wiring: `config/auth.rb`, the `login_tokens`/`sessions` migration,
  `AUTH_SECRET`, `app/mailers/auth_mailer.rb`,
  `app/views/mail/magic_link.erb`.
- Example `auth-routes`, in `app/routes/auth.rb`: request link, callback,
  logout, and one protected route, all commented. They're not live
  because they carry the app's own decisions: the per-email rate limit
  (without it, a live `/auth/request` lets anyone send unlimited mail to
  any address), the `redirect_to` allowlist, HTML or JSON. The block
  shows both ways to send: `Monk::Auth.deliver_link` in the request, or
  `Monk::Auth::SendLoginLink.enqueue` with jobs (decision 9). The login
  form, `app/views/auth/login.erb`, is a real file. Settled 2026-10-08:
  - The page sends the email with `fetch` and a JSON body: Monk parses
    only query strings and JSON bodies into `params`, and `require_csrf!`
    reads only the `X-CSRF-Token` header, so a plain HTML form can't work
    yet. Parsing form bodies is a roadmap item ("Richer HTML support").
  - Logout uses a new `log_out!` helper (`Monk::Auth::Helpers`): it
    revokes the current session, cookie or Bearer, and clears the
    cookies. The token reader it needs was private.
- Proof: `test/auth_test.rb`: `request_login` → `deliver_link`, which
  reaches `log://` → `redeem` → a valid session. It checks the tables,
  the secret and the mailer without any route.
- Setup: change `AUTH_SECRET`, uncomment the routes, add the rate limit.

### jobs (pulls in postgres)
- Wiring: `config/jobs.rb`, `bin/jobs`, the queue's migration,
  `JOBS_WORKERS`/`JOBS_QUEUES`.
- Example: `app/jobs/hello_job.rb` is real code (a file in its own role
  directory does no harm). Example `jobs-enqueue`, the route that
  enqueues it, is commented in `app/routes/jobs.rb`. The `POST
  /jobs/hello` anchor in `app/app.rb` goes away.
- Proof: `test/jobs_test.rb`: `enqueue` + `drain!`, today's SETUP.md
  sample made into a file.
- Setup: run `bin/jobs` next to `bin/server`, and from `bin/console`
  enqueue `HelloJob` to see it run.
- With recurring jobs (`main_dev/scheduled_job`, see "Other branches"
  below):
  - the generator writes two migrations, the queue's and
    `create_recurring_tables`, both timestamped;
  - the commented `recurring` example in `config/jobs.rb` becomes a tagged
    block, `jobs-recurring`;
  - `test/jobs_test.rb` doesn't cover it: the scheduler runs on
    `bin/jobs`'s tick, which a generated test doesn't start.

### redis
- Wiring: the `redis` gem; `REDIS_URL` in `.env`, `.env.test` and
  `.env.example`; `config/redis.rb` declaring the `redis_url` setting
  (default `redis://localhost:6379/0` in development and test, required
  elsewhere).
- Example `redis-cache`, commented in `app/routes/redis.rb`: read
  through a cache key with a TTL. Monk has no Redis connection handling
  like `Pg.pool`, so the example opens its client inside the block (a
  client isn't Ractor-shareable). The example's comment and the AGENTS.md
  section say so. A Redis pool is a separate roadmap item, not this
  plan.
- Proof: `test/redis_test.rb` runs `PING` against `REDIS_URL`.
- Setup: start Redis (`docker run … redis:7`), and check whether one is
  already running from another project, as SETUP.md says today.

### websocket (pulls in its transport: postgres or redis)
- Wiring: `config/websocket.rb` with `AppWebSocket::REGISTRY` over the
  chosen transport, `bin/websocket_server`, `WS_PORT`,
  `WS_ALLOWED_ORIGINS` (decision 13).
- Example `websocket-chat`: today's chat handler, commented, in
  `app/sockets/chat.rb`.
- Proof: `test/websocket_test.rb` boots the server on a free port and
  completes a handshake, then checks one broadcast reaches the registry
  through the transport.
- Setup: run it next to `bin/server`; origins; `wss://` in production;
  with Postgres, the 8 KB `NOTIFY` limit per broadcast.

### live (pulls in websocket)
- Wiring: `config/live.rb`, configured with `AppWebSocket::REGISTRY`, so
  it has no transport of its own. The layout tags come from `monk_head`
  and the client from the gem (decisions 11, 12).
- Examples:
  - `live-rule`, commented in `config/live.rb`. There's no working rule
    by default, so nothing can be subscribed to until the app writes
    one; today's "anyone may subscribe to `hits`" goes.
  - `live-broadcast`, commented in `app/broadcasts/`: `Monk::Live.patch`,
    the `live_topic` snippet for a view, and the route that triggers it.
- Proof: `test/live_test.rb` publishes through the configured fanout and
  checks a subscriber receives it. Phase 4 checks this can run in one
  test process for both transports; if it can't, the test stops at
  "publish is accepted and rendered" and the demo covers the rest.
- Demo (decision 14): `/demo/live`, development only, `--no-demo` to
  skip. It carries its own authorization rule for `demo:hits`, also only
  in development.
- Setup: `LIVE_WS_URL`, and opening `/demo/live` in two tabs. Processes,
  origins and transport limits are in websocket's section.

### storage (on its own branch)
[`plan-storage.md`](https://github.com/matteofuzz/monk/blob/main_dev/monk_storage/docs/plan-storage.md)'s
Phase 8 becomes `lib/monk/generators/storage.rb`, following this plan:
- Wiring: `config/storage.rb`, `STORAGE_*` commented in the env files,
  `/storage/` in `.gitignore` and `.dockerignore`.
- Example `storage-routes`, in `app/routes/storage.rb`: presign, confirm,
  and `/media/:id` **with its access check written in**, plus the
  `attachments` SQL, all commented. This replaces Phase 8's working
  development-only routes: a working `/media/*key` has no access check.
  `public/js/upload.js` is a real file that does nothing until a page
  includes it.
- Proof: `test/storage_test.rb`: presign → PUT → confirm → signed link,
  on the file backend.

## Other branches that touch the scaffold

Two plans on their own branches change what `monk new` writes today:

- **storage** (`main_dev/monk_storage`, `plan-storage.md` Phase 8): see
  the storage section above.
- **recurring jobs** (`main_dev/scheduled_job`, `plan-scheduled-jobs.md`
  decision 6, "Scaffolding"): `monk new --jobs` ships a third migration
  (`00000000000003_create_recurring_tables`), `config/jobs.rb` gets a
  commented `recurring` example, and `scaffold_jobs_test.rb` covers both.
  Here that becomes the jobs generator's second migration and its
  `jobs-recurring` example (see the jobs section above).

**Order (decided 2026-10-08): this plan first, then recurring jobs, then
storage.** Neither branch has built its scaffold step yet, so each one
rewrites it as a change to a generator before starting, following
decisions 2, 5, 15 and 16:
- **recurring jobs:** the second migration and the `jobs-recurring`
  example in the jobs generator;
- **storage:** `lib/monk/generators/storage.rb`, as in the storage section
  above, instead of `monk new --storage` and its working demo routes.

Neither ever touches `Monk::Scaffold`, which Phase 7 deletes.

Two cross-effects to remember:
- **An app that installed jobs before recurring jobs existed** has no
  `create_recurring_tables` migration, and `monk add jobs` only says
  "already installed". The scheduled-jobs plan's decision 9 (`bin/jobs`
  raises at start and names the migration to copy) covers it. Under
  this plan, that error also names
  `monk help jobs --file <migration>` to print the file. Catching
  this before deploy is one of `monk check`'s roadmap uses, "after
  upgrading Monk".
- **Cleaning up `Monk::Auth`'s expired rows** (on the roadmap, waiting
  for recurring jobs) needs auth and jobs both installed. Like decisions
  8 and 9, it lives in the framework: `Monk::Auth` declares its own
  recurring sweep when `Monk::Jobs` is loaded, so no generator rule is
  needed for it.

## Phases

Each step is a small red → green slice, as in the earlier plans. Phases
1–2 change today's `Monk::Scaffold` too, so it keeps working, its tests
stay green, and the anchors go away before the generators exist.

### Phase 0: ADR
`adr/0017-scaffold-by-module-generators.md`. It covers:
- generators instead of flags;
- wiring / example / test;
- the live-only demo;
- `app/routes/` (amending ADR 0015's "Routes split into `app/routes/*.rb`
  from the start", with a pointer added to 0015);
- WebSocket as a module;
- AGENTS.md.

Considered and rejected:
- keeping the flags with a cleaner internal structure: the combinations
  stay, and a module still can't be added later;
- an interactive-only `monk new`: a UI, not a structure;
- demos for every module;
- `monk check` instead of generated tests: tests stay in the app, and an
  agent gets an exit code from them.

### Phase 1: the framework takes over the pair rules
1. `monk/mail` ↔ `monk/jobs` load `mail/later` in either order
   (decision 8). Test both orders.
2. The `JOBS_QUEUES` default.
3. `Monk::Auth::SendLoginLink` (decision 9). Move
   `templates/jobs/app/jobs/send_login_link.rb`'s tests to it.
4. `monk_head` and the head-tag registry. Live registers its tags
   (decision 11).
5. Live's client served from the gem (decision 12), or record the
   fallback.
6. Point `Monk::Scaffold` at 1–5: drop `add_deliver_later!`,
   `JOBS_AUTH_FILES` and `add_live_to_layout!`.

### Phase 2: static base templates
1. The static `config/load.rb` (decision 6). Drop `wire_load!`.
2. `app/app.rb` loads `app/routes/`. The `--jobs` route moves to
   `app/routes/jobs.rb`, and the `--live` demo to `demo_live.rb` +
   `app/views/demo/`. Drop `JOBS_ROUTE_ANCHOR` and the `app/app.rb` and
   `index.erb` overrides.
3. Dotenv always on (decision 17).
4. The test setup in the base app (decision 18).
5. The Dockerfile (decision 21): check the precompiled `pg` gem first.
6. ~~`config/websocket.rb` with `AppWebSocket::REGISTRY`~~ Moved to
   Phase 4 (settled 2026-10-08): done now, it needed a temporary
   in-process variant for apps with neither transport, deleted again in
   Phase 7. The websocket generator builds `config/websocket.rb`, the new
   `bin/websocket_server` and `app/sockets/chat.rb` once, in their final
   form; until then the old scaffold keeps its two `bin/websocket_server`
   files.
7. The `bin/` scripts' errors (decision 29): an unreachable Postgres or
   Redis, or a missing setting, prints what failed, the setting, and
   SETUP.md's commands, then exits 1. One test per script.

### Phase 3: the generator engine
`Monk::Generator` and its DSL:
```ruby
Monk::Generator.define :jobs do
  summary "Background jobs on Postgres (Monk::Jobs)"
  depends_on :postgres
  installed_if "config/jobs.rb"
  copy "config/jobs.rb", "app/jobs/hello_job.rb", "app/routes/jobs.rb", "test/jobs_test.rb"
  copy "bin/jobs", executable: true
  migration "create_jobs_tables"
  env development: { JOBS_WORKERS: "2", JOBS_QUEUES: "mailers,default" },
      example: { JOBS_WORKERS: "2", JOBS_QUEUES: "mailers,default" }
  setup_section "jobs/setup.md"
  agents_section "jobs/agents.md"
  next_step "run bin/jobs next to bin/server"
end
```
Its parts:
- the actions;
- idempotency;
- file roles and conflicts, every file checked before any is written
  (decision 26);
- dependency order (a cycle is an error);
- `--dry-run`;
- services (`service :postgres, check: "pg_isready …", setup:
  "SETUP.md#postgres"`);
- example `todo`s;
- the `Result`, with its text form (decision 25), its JSON form
  (decision 27) and its exit code (decision 28).

Tested on temporary directories with fake modules, before any real one.

### Phase 4: the generators
From here on the generators own `templates/` (settled 2026-10-08): when a
template change breaks a test of the old `Monk::Scaffold`, that test is
removed in the same commit, as long as a generator test covers the
behaviour. Until Phase 5 switches the CLI, `monk new` on this branch may
produce an inconsistent app; Phase 7 deletes what's left.

One slice per module, in dependency order: base, postgres, redis, mail,
auth, jobs, websocket (with each transport), live. The websocket slice
also does what Phase 2 step 6 deferred: `config/websocket.rb` with
`AppWebSocket::REGISTRY`, the new `bin/websocket_server`, and
`config/live.rb` using the same registry (decision 13). For each:
- the files and appended lines, exactly;
- running it twice changes nothing;
- the generated app's own `rake test` passes;
- its example blocks pass `examples_test.rb`;
- its SETUP and AGENTS sections.

Live also gets the demo, the `--no-demo` path, and the in-process fanout
check (see live's proof).

### Phase 5: the CLI
`lib/monk/cli.rb`, with `exe/monk` reduced to calling it:
- `new`, `add`, `add --list` and `help [MODULE]`, with HELP built from
  the generators;
- `--with`, `--no-demo`, `--transport`, `--dry-run`, `--json`;
- the non-terminal rule (decision 23);
- the old flags as a usage error showing the new form, with nothing
  written (decision 24).

`test/exe_monk_test.rb` grows to cover each of these. It also pins:
- the JSON schema, for every `status`;
- every exit code;
- the text output of one full session: the simulated `shop` session
  from the review (`new`, `add auth`, `add jobs`, `add redis`,
  `add live` with the prompt, `--dry-run`, a skipped file, an old
  flag, the non-terminal error).

### Phase 6: properties across modules
`combinations_test.rb` checks:
- **Order independence**: for every pair, A then B gives the same tree
  as B then A, and as `--with a,b`.
- **`add` matches `new`**: `monk add` on an existing base app gives the
  same tree as `monk new --with`.
- **Every combination boots**: each valid set of the seven modules,
  with each transport where websocket is in it, boots and passes its own
  tests. If that's too slow, use every pair plus the full set with each
  transport, and run the rest under a `SLOW=1` env var.
- **Transport inference**: `--with jobs,live` picks postgres,
  `--with redis,live` picks redis, and `--with live` alone or
  `--with postgres,redis,live` asks (or errors without a terminal).

### Phase 7: delete the old scaffold
`lib/monk/scaffold.rb`, `Monk::AmbiguousLiveTransportError` (replaced by
the CLI's error for a missing `--transport`), the override templates, the
`scaffold_*` tests and `scaffold_summary_test.rb` (`--with` reports
added dependencies in its result instead).

### Phase 8: docs
- `docs/guides/scaffolding.md` rewritten around `monk new`/`monk add`, one
  section per module.
- README's module table and quick start.
- CHANGELOG: the old flags are gone (a breaking change), replaced by
  `--with` and `monk add`.
- `docs/roadmap.md`.
- A note at the top of `plan-scheduled-jobs.md` and `plan-storage.md`, on
  their branches, pointing their scaffold steps at the generators (see
  "Other branches that touch the scaffold").
- When everything is done, this plan moves to `docs/history/`.

### Phase 9 (optional): interactive `monk new`
With a terminal and no `--with`, ask which modules to add, a checklist
built from the generators. It's only a front end on `--with`.

## Still open

Nothing. Ergonomics were settled on 2026-10-08 in two simulated sessions,
one as a person and one as an agent (decisions 25–30). Changing
websocket's transport later is documented (decision 13). `monk check`
moved to `docs/roadmap.md` as its own feature, building on decision 29's
service checks.
