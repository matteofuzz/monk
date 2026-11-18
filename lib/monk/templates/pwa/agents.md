## pwa

**Where:** `public/manifest.webmanifest`, `public/icons/`,
`public/sw.js`; `config/pwa.rb` calls `Monk::Pwa.configure`.

**How it works:** `configure` checks at boot that the manifest is valid
JSON with `name`, `short_name`, `start_url`, an installable `display`, a
192 and a 512 icon, and that every file it names exists, as do `sw.js` and
`icons/apple-touch-icon.png`; otherwise the boot fails with
`Monk::Pwa::InvalidManifestError`. `<%= monk_head %>` links the manifest
and the icon, and loads `/_monk/pwa/register.js`, which registers `/sw.js`
and reports `monk-pwa:registered`, `monk-pwa:unsupported` or
`monk-pwa:failed` on `document`.

**Test:** `test/pwa_test.rb` requests the manifest, its icons and
`sw.js`, and checks a page links them.

**Pitfalls:**
- `sw.js` has no `fetch` handler, on purpose: one would see every request,
  Monk::Live's resync refetch and login redirects included. Don't add
  caching without keeping those out.
- Link the manifest and `sw.js` by their plain paths, never with
  `asset_path`: a service worker's URL is its identity.
- Service workers need https or localhost.
