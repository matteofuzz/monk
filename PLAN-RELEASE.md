# Releasing as `monkrb` — checklist

Target: week of 2026-09-22. Background and the deployment consequences
are in `docs/deployment-options.md` §2; `monkrb` was confirmed unclaimed
on RubyGems on 2026-09-19.

## Rename

- [ ] `monk.gemspec` → `monkrb.gemspec`; `spec.name = "monkrb"` (Bundler's
      `gemspec` directive picks it up by directory, so the root `Gemfile`
      needs no change)
- [ ] Add `rubygems_mfa_required` to `spec.metadata`
- [ ] `lib/monk/templates/base/Gemfile`: `gem "monkrb"`, with a comment
      that the require path stays `monk`
- [ ] README: install line, plus one line that the gem name ≠ the require
      path (`gem "monkrb"` / `require "monk"`)
- [ ] `NOTES-V2.md`: close the "a rename will be needed before ever
      publishing" note
- [ ] CHANGELOG entry + version bump

## Verify before push

- [ ] `gem build` from a clean checkout, then `gem contents` — confirm
      `spec.files` isn't empty (it shells out to `git ls-files`, which
      yields nothing outside a git checkout)
- [ ] `monk new` a throwaway app against the built gem, `bundle install`,
      boot it under kino
- [ ] Confirm `exe/monk` installs without clobbering anything — the 2009
      `monk` gem ships an executable of the same name
- [ ] `gem push` with MFA

## Deployment prerequisites, same week

- [ ] `bundle lock --add-platform x86_64-linux aarch64-linux` in the
      scaffold or its `SETUP.md` — kino's precompiled binaries, unaffected
      by the rename
- [ ] `docs/deploying.md`: drop `git` from the Fly Dockerfile's runtime
      stage, update `gem "monk"` references
- [ ] `docs/deployment-options.md` §2/§7.3: flip "on release" to past
      tense once pushed
