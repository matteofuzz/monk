# Settings is a new facility, not a retrofit of Persistence/Auth config

Monk already has two per-feature config surfaces — `Persistence.register` and `Auth.configure` — each with its own bespoke, boot-frozen storage. Rather than route those through the new generic `Settings` facility (or route `Settings` through one of them), we decided `Settings` is a third, separate mechanism: for `MONK_ENV` and arbitrary app-defined values, leaving `Persistence`/`Auth` exactly as they are. We rejected retrofitting the existing two because they already work, and folding them into a new facility as a side effect of building it is a larger, riskier refactor with no stated need — the three surfaces sharing the same underlying discipline (declared before `Boot`, frozen via `freeze_hooks`, fail-fast on missing required values) is enough consistency without forcing one literal implementation.

## Considered Options

- Retrofit `Persistence.register`/`Auth.configure` to store their values through `Settings` internally (rejected: touches two working subsystems as a side effect of building a third, for no stated benefit)
- Have `Settings` wrap or delegate to whichever of `Persistence`/`Auth` already exists for overlapping keys (rejected: no overlap actually exists — `Persistence`/`Auth` config is backend-specific (`db_name`, `secret`, TTLs), `Settings` is for `MONK_ENV` and app-defined values neither of those was ever meant to hold)
