# TODO — release Monk to RubyGems as `monkrb`

## Done
- [x] Rename `monk.gemspec` → `monkrb.gemspec`, `spec.name = "monkrb"` (code namespace stays `Monk::`/`require "monk"`)
- [x] Add gemspec metadata: `source_code_uri`, `changelog_uri`, `bug_tracker_uri`, `rubygems_mfa_required`
- [x] Fix scaffold template `lib/monk/templates/base/Gemfile`: `gem "monk"` → `gem "monkrb", require: "monk"`
- [x] Update `docs/guides/deploying.md` references from `monk.gemspec`/`gem "monk"` to `monkrb`
- [x] Fix stale `monk.gemspec` entry in `.rubocop_todo.yml`
- [x] Verify `bundle install`, full test suite, and `rake rubocop` are clean

## Remaining

### README updates
- [ ] Update **Status** paragraph: [issue #19](https://github.com/matteofuzz/monk/issues/19) ("V2 - MONK plan") is now **closed** and the roadmap is empty — rewrite to stop pointing at it as the living list of pending work, and either drop the roadmap sentence or state that there's currently no open roadmap issue
- [ ] Add/update install instructions to reference the published gem name: `gem "monkrb", require: "monk"` in a Gemfile (and/or `gem install monkrb`), distinct from the `require "monk"` code namespace
- [ ] Sweep README for any other stale references to the old `monk` gem name vs. the `monkrb` package name

### Publishing (requires manual/account action)
- [ ] Create/confirm RubyGems account for matteo.folin@gmail.com, enable MFA
- [ ] Set up auth for publishing: `gem signin` + `gem push`, or Trusted Publishing (OIDC via GitHub Actions) — recommended
- [ ] Decide first published version (currently `0.14.0` in `lib/monk/version.rb`)
- [ ] `gem build monkrb.gemspec` and `gem push monkrb-<version>.gem`
- [ ] Commit and push the local gemspec/scaffold/docs/README changes

### Optional
- [ ] Add a GitHub Actions release workflow (trusted publishing, triggered on a version tag)
- [ ] Add a CHANGELOG entry noting the RubyGems release / gem name
