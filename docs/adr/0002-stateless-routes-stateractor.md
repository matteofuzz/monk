# Stateless route closures + StateRactor for shared mutable state

Ractors cannot share mutable Ruby objects across their boundary, so a route block that closes over outer mutable state (e.g. a hit counter, an in-memory cache) cannot be made `Ractor.shareable?` and cannot run inside worker Ractors. We considered three approaches: (a) disallow shared mutable state entirely in v1, (b) provide a built-in message-passing primitive for it, and (c) allow only per-worker-local mutable state with no cross-worker consistency. We chose a combination of (a) and (b): route closures must be stateless, and any cross-request mutable state must go through `StateRactor`, a user-instantiated primitive that wraps mutable state inside its own dedicated Ractor and exposes it via synchronous message-passing calls. This works because a `Ractor` instance is always `Ractor.shareable?` regardless of the mutable state it encapsulates internally, so a route can safely close over a `StateRactor` handle without violating shareability. Per-worker-local state (option c) was rejected as a default because its silent inconsistency across workers is a common source of surprising bugs (e.g. a "hit counter" that returns different values depending on which worker handled the request).

## Considered Options

- Per-worker-local mutable state (rejected: inconsistent, surprising results across workers)
- A single implicit global state layer built into the framework (rejected: guesses at use cases prematurely; a general-purpose primitive is more minimal)
