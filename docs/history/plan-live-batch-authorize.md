# Plan: 0.30, batched topic authorization in Live

Status: released in 0.30.0 (2026-11-27). Release branch `main_dev/v_0_30`,
no feature branch (one change).

Built (2026-11-27): steps 1 to 4, the suite green with 0 skips. One
difference: `build_rule` takes `db_pool:` and `batch:` as keywords. Step
5, the bump to 0.30.0, done the same day.

## The problem

`Session#subscribe(topics)` gets a page's topics in one message, then
checks them one at a time (`try_subscribe?` → `permitted?` →
`Policy.allowed?`). A rule with `db_pool:` costs one pool round trip, and
usually one query, per topic. A page showing a status per person
subscribes to one topic per row (up to ~100), so one connect is ~100
sequential queries through a pool shared by every socket of the process.
Since 0.29 every page load connects and resyncs (ADR 0021) and every
phone resume reconnects; in a reconnect wave this is pages × rows queries
through a handful of connections. The registry step after the check is
already batched (`register_many`); the check isn't.

## The change

```ruby
module AppLive
  SHOWN = proc do |subject, topics|
    keys = topics.map { |topic| topic.delete_prefix("presence:") }
    Person.shown_keys(subject, keys).map { |key| "presence:#{key}" }
  end
end
Monk::Live.authorize("presence:*", db_pool: :live, batch: true, &AppLive::SHOWN)
```

A `batch: true` rule's block gets the subject and every topic of one
subscribe message that this rule decides, and returns the allowed ones.
One call per message, so one pool call with `db_pool:`.

## Review of the proposal

Agreed as proposed: the opt-in rule, first match wins across both kinds,
fail closed per group, anonymous denied before the block, `authorized?`
calling the block with `[topic]`, no wire or client change, the rejected
fan-out-on-write alternative. Points the proposal left open, settled:

1. **Keyword: `batch: true`**, not `authorize_many`. Same pattern,
   `anonymous:` and `db_pool:`, one ordered rule list (first match wins
   needs one list anyway), no new method. Stored as a `batch` field on
   `Policy::Rule`.
2. **No group cap.** A group is at most `MAX_TOPICS_PER_MESSAGE` (100),
   since the message is checked against it before anything else. The
   guide says so, so the app's SQL can count on it.
3. **Return value: an Array or a Set** (of Strings). It is intersected
   with the group: anything not asked for is ignored, anything not
   returned is denied. `nil` or `false` denies the group (a block that
   finds nothing may return either). Any other value (`true`, a Hash, a
   String) denies the group and logs: a batch rule must say which topics,
   and `true` must never mean "all".
4. **Cap after the check, as today.** Today's outcome is kept exactly:
   checks first, then topics added in the message's order while the
   connection has room; a denied topic takes no slot. (Today a topic is
   also checked when the connection is already full; that stays, it's
   rare and checking first keeps the code one shape.)

Found in review, not in the proposal:

5. **A batch block registered without `batch: true` would fail open.** It
   gets a String, returns an Array (even `[]`), and an Array is truthy, so
   today's `run(...) ? true : false` allows. Fix: a single-topic rule whose
   block returns an Array, Set or Hash denies and logs ("returned a
   collection: a batch rule needs batch: true"). Existing rules returning
   a collection as "truthy" are the only thing this changes; the
   upgrading guide says so. The other mistake (`batch: true` on a
   single-topic block) already fails closed: the block gets an Array,
   and returns `true`/`false` or raises, which point 3 denies.
6. **Duplicate topics in one message.** Today the second copy passes as
   already added. The batch path decides each distinct topic once (the
   group is `uniq`), and the reply still lists the message's topics as
   today.
7. **Logging.** A pool failure logs once per group, as `log_pool_failure`
   does, but with the rule and the group's size, not up to 100 topic
   names. A block that raises is silent today; a whole page's statuses
   vanishing silently is hard to debug, so a raising block now logs one
   line (rule, exception class and message) for both kinds of rule.
8. **Where the grouping lives: `Policy`, not `Session`.** A new
   `Policy.allowed_topics(rules, subject, topics) → Set` takes topics
   that already passed `TOPIC_FORMAT` and aren't subscribed, groups them
   by first matching rule (in order of first appearance), runs single
   rules per topic and batch rules once, and returns the allowed ones.
   `Policy.allowed?(rules, subject, topic)` becomes
   `allowed_topics(rules, subject, [topic]).include?(topic)`, which gives
   `Monk::Live.authorized?` the `[topic]` behavior for free. `Session`
   keeps only the order, the cap and `register_many`.
9. **Pool call.** `pool.call(Policy, :check_many, rule.check, subject,
   group)`: the group crosses as a frozen Array of frozen Strings, the
   result comes back copied. One checkout holds a connection for one
   `ANY($2::text[])` query instead of up to 100 short ones; well inside
   the pool's checkout timeout.
10. **Version: 0.30**, a minor: new public API (`batch:`), and point 5
    changes what an existing (mistaken) rule does.

## Steps

1. **Policy.** `Rule` gains `batch`; `build_rule` takes it (a boolean,
   checked); `allowed_topics` with the grouping, the return-value check
   (points 3, 5), the logging (point 7); `check_many` for the pool;
   `allowed?` on top of it. `Monk::Live.authorize(pattern, anonymous:,
   db_pool:, batch: false, &block)`.
2. **Session.** `subscribe`: drop already-subscribed and malformed topics,
   one `Policy.allowed_topics` for the rest, then the message's order
   with the cap, `register_many`, the reply. `try_subscribe?` and
   `permitted?` go.
3. **Tests** (below), the suite with 0 skips.
4. **Docs.** `docs/guides/live.md` "Who may subscribe": the batch rule,
   when to use it (a rule that queries, a page with many topics of one
   kind), the example with `ANY($2::text[])`, the 100 bound, the return
   value. ADR 0009: an *Amended in 0.30* note (a rule may decide a
   message's topics in one call; deny by default and first match
   unchanged). `Policy`'s and `authorize`'s comments. CHANGELOG. The
   upgrading guide: opt-in, nothing to do, except point 5.
5. **Version bump** to 0.30.0, on the user's say.

## Tests

`test/live_policy_test.rb`:
- a batch rule is called once with only its matching topics; a single
  rule beside it still runs per topic; first match wins across the two
  kinds (a specific single rule above a batch `*` rule, and the reverse);
- the return value: an Array and a Set allow what they list; a topic not
  asked for is ignored; `nil`/`false` deny all; `true` or a Hash deny all
  and log;
- a block that raises denies the group and logs (both kinds);
- a single-topic rule returning an Array/Set/Hash denies and logs;
- an anonymous subject is denied without calling the block, unless
  `anonymous: true`;
- `authorized?` with a batch rule (block gets `[topic]`);
- `build_rule` rejects a non-boolean `batch:`; a batch rule is shareable
  and runs from a non-main Ractor.

`test/live_pool_test.rb`:
- a batch rule with `db_pool:` makes one pool call per message (counted);
- the pool not started, timed out, full: the whole group denied, one
  log line naming the rule and the group's size.

`test/live_session_test.rb`:
- a subscribe with mixed topics: the reply's `topics`/`denied` as today;
  the batch block never sees already-subscribed or malformed topics;
- the cap after the check: denied topics take no slot, the overflow in
  the message's order is denied;
- a duplicate topic in one message: checked once, listed as today.

## Not in 0.30

- A cap on the group below 100, or a separate `authorize_many`.
- Skipping the check once a connection is full.
- Anything on the client or the wire.
