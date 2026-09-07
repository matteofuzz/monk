# Persistence — open list of possible evolutions

Status: living list, not a roadmap or a commitment. A place to record
things considered for `Monk::Persistence::Pg::Model` (and the underlying
`Pg`/`Registry` layer) that aren't built yet, so the reasoning behind
punting on each one isn't lost between conversations. Add an item when
it comes up in discussion/review; when one is actually built, strike it
(keep the entry, note the date and what shipped) rather than deleting it.

## 1. `where` — OR / arbitrary boolean trees

**Status**: open, not started. **Complexity**: high.

`where` is AND-only (`docs/persistence-ractor-connections.md` decision 4,
and its 2026-09-07 update after gap 1 of `docs/chat-gap-analysis.md` added
comparison operators/`IN`/`ORDER BY`/`LIMIT`). A query like "sender=A and
recipient=B, or the reverse" — needed for a 1:1 chat conversation's full
history — has no representation in a flat conditions hash and still falls
back to a raw `Pg.checkout` block in an app-level repository.

Adding OR isn't a small syntax tweak: it means `where` stops being "AND a
flat hash" and becomes a real expression-tree DSL — grouping, precedence,
how deep nesting is allowed before it's just SQL with extra steps. No
syntax has been chosen (nested arrays? `Sequel`-style `.|(...)`? something
Monk-specific?); this is a real design decision, not just an
implementation task, and the kind of scope growth `PLAN-PERSISTENCE.md`
explicitly deferred ("no query-condition DSL beyond equality + AND").

## 2. Batch update

**Status**: open, not started. Two different shapes, two different
complexity levels — see the batch-operations analysis, 2026-09-07.

- **2a. Same data applied to many ids** (`update_all(ids, data)` — e.g.
  "mark these N messages read"). Low complexity: `UPDATE t SET ... WHERE
  id IN (...) RETURNING *`, symmetric with the existing `update`. Not
  built only because nothing has needed it yet; the most likely of
  everything on this list to get picked up next.
- **2b. Different data per row** (bulk upsert-style — every id gets its
  own values in one round trip). High complexity: needs Postgres's
  `UPDATE ... FROM (VALUES ...) AS v(id, col1, ...)` pattern, which runs
  into real VALUES type-inference pitfalls (a `NULL` in the first row, or
  mixed column types like timestamps/uuids/jsonb, routinely produce wrong-
  type errors) that would likely need schema introspection
  (`information_schema`/`pg_type`, cached somewhere) to solve properly —
  a bigger commitment than anything `where` needed. Also an open question
  on result shape: only the rows that actually matched, or a positional
  array with `nil` gaps (mirroring `find_all`)?

## 3. Transactions

**Status**: open, not started. **Complexity**: moderate-to-high — see the
transactions analysis, 2026-09-07. The first persistence feature that
would touch the shared `Monk::Persistence::Registry` checkout mechanism
itself, not just SQL generation inside `Model`.

`checkout` would need to become transaction-aware: reuse the same
connection across multiple `Model` calls inside a `.transaction` block
instead of checking it in and back out per statement. That surfaces a
real correctness trap, not just plumbing — the "am I inside a
transaction" marker must be **thread-local**, not Ractor-local, or two
sibling threads under `:threaded` mode (3 threads sharing one Ractor's one
connection, per Kino's default) could end up issuing commands on the same
live connection concurrently: the exact wire-protocol-corruption failure
the `SizedQueue`-based checkout exists to prevent in the first place (same
failure category as the Phase 4/5 Ractor-shareability bugs recorded in
`docs/persistence-ractor-connections.md`, just about thread-locality
instead).

Also needs an explicit decision before any code gets written: nested
`.transaction` calls flatten into the outer one (simple, one depth
counter, fits this codebase's "small primitive" style), or get real
`SAVEPOINT`-based independent rollback (ActiveRecord's `requires_new:`
territory — meaningfully more machinery, no known need for it yet).

Explicitly still out regardless of how this lands: cross-database
transactions (`PLAN-PERSISTENCE.md`, "Explicitly out of scope" — no
distributed/2PC story, and none planned).

## (room for more)

Add items here as they surface — a candidate only needs a one-line
"what" and a rough complexity/status note to start; flesh it out with a
dated analysis (inline or linked) once it's actually being considered for
real.
