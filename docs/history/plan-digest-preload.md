# Loading digest classes at boot — plan

Drafted and done 2026-10-22, in monkrb 0.22.2, on
`main_dev/v_0_22_2`. Found by the monk-vs-rails benchmark: its
WebSocket server's log had a connection's thread dead in the handshake.
Its plan sends Monk bugs found while running to a Monk plan of their
own, and a fix released before its next session goes into that session.

## The problem

In the benchmark's WebSocket server log (0.22.1), a connection's thread
died during the handshake with "Digest::Base cannot be directly
inherited in Ruby", at `monk/websocket/handshake.rb:17`, the line that
calls `Digest::SHA1.digest`.

The same error is in a local run from 2026-10-13, on 0.21.1 with one
server process, so neither 0.22.1's `WS_PROCESSES` nor its handshake
rewrite caused it.

## Why

`handshake.rb` required only `digest`. That loads Digest's Ruby part,
not SHA1: `Digest.const_missing` requires `digest/sha1` the first time
code names `Digest::SHA1`, in whichever Ractor names it first. Loading
the C extension takes two steps:

1. define the class: the constant `Digest::SHA1` exists, for every
   Ractor;
2. attach its metadata (the hash functions and state size), which
   `Digest::Base` looks up on every call.

`.digest` with no metadata found raises "Digest::Base cannot be directly
inherited in Ruby": the error meant for a Ruby subclass of
`Digest::Base`, which is what a class without metadata looks like.

Under the GVL nothing ran between the two steps. Connection Ractors run
in parallel: a second connection that names `Digest::SHA1` between them
finds the constant, so `const_missing` never runs for it and it doesn't
wait for the load, and `.digest` raises. It takes two handshakes as the
first ones after boot, at the same moment: a connect burst. Once step 2
is done the class is complete, so a process fails at most at its start.

What doesn't reproduce it, on Ruby 4.0.6 and digest 3.2.1: one Ractor;
16 Ractors, or 8 Ractors of 8 threads, racing on first use; SHA256
loaded first; the real `Server` taking 20 handshakes at once. The window
is a few instructions wide. What does: Ractors that wait for the
constant to appear and call `.digest` at once fail in every run.

## Where else

Every `Digest::` use in `lib/`:

| file | class | from a Ractor? |
|---|---|---|
| `websocket/handshake.rb` | SHA1 | yes: every handshake, in its connection Ractor |
| `auth.rb` (`hash_token`) | SHA256 | yes: web workers, and connection Ractors with `authenticate:` |
| `assets.rb` (`entry_for`) | SHA256 | in development: each asset request, in a worker Ractor. In production the manifest is built at boot, in the main Ractor |

## The fix

Each file requires the extension it uses, next to `require "digest"`:
`digest/sha1` in `handshake.rb`, `digest/sha2` in `auth.rb` and
`assets.rb` (`const_missing` maps SHA256 to `digest/sha2`). It loads
when the Monk library is required, at boot, in the main Ractor, before
any worker or connection Ractor exists, so no Ractor ever finds the
class half-defined.

Rejected:

- A warm-up call at boot (one `accept_key`): the same effect, but
  nothing says why it's there, and it reads as dead code.
- A lock around the call: the Ractor that fails never reaches
  `const_missing`, so there's nothing for Monk to lock, and Ractors
  can't share a `Mutex` anyway.
- Fixing digest to attach the metadata before it defines the constant:
  the root fix, worth an issue upstream, but Monk can't wait for it to
  ship.

## Test

`test/digest_preload_test.rb`, one case per library. Each runs a fresh
Ruby (this suite has loaded every digest class already), requires the
library, then starts six Ractors that wait for the constant and call
`.digest` the moment it appears, and one more that names it first. It
passes when none raises.

Red → green, one slice per library:

| slice | red, before its require | green, after |
|---|---|---|
| `monk/websocket`, SHA1 | 3 of 3 runs, 5–6 of 7 Ractors raising | 5 of 5 |
| `monk/auth`, SHA256 | 3 of 3, 6 of 7 | 5 of 5 |
| `monk/assets`, SHA256 | 3 of 3, 4–6 of 7 | 5 of 5 |

Full suite: 1071 runs, 0 failures (Postgres-backed tests skipped, no
database configured).

## Open

- An issue on ruby/digest for the order of the two steps.
- Apps: nothing to change (`docs/guides/upgrading.md`, 0.22.2).
