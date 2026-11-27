## pwa

**Where:** `public/manifest.webmanifest`, `public/icons/`,
`public/sw.js`, `public/offline.html`; `config/pwa.rb` calls
`Monk::Pwa.configure`.

**How it works:** `configure` checks at boot that the manifest is valid
JSON with `name`, `short_name`, `start_url`, an installable `display`, a
192 and a 512 icon, and that every file it names exists, as do `sw.js`,
`offline.html` and `icons/apple-touch-icon.png`; otherwise the boot fails
with `Monk::Pwa::InvalidManifestError`. `<%= monk_head %>` links the manifest
and the icon, and loads `/_monk/pwa/register.js`, which registers `/sw.js`
and reports `monk-pwa:registered`, `monk-pwa:unsupported`,
`monk-pwa:failed`, `monk-pwa:installable` and `monk-pwa:installed` on
`document`. It also sets `data-pwa-standalone`, `data-pwa-platform`
(`ios`/`android`/`other`), `data-pwa-installable` and `data-pwa-in-app`
on `<html>`, for CSS. `<%= monk_install %>` renders an install banner
(hidden until it applies; BEM classes, no styles).

**Offline:** `/_monk/pwa/offline.js` (also loaded by `monk_head`) sets
`<html data-monk-offline="network|server|unreachable">` after 2 s without
a connection, shows `<%= monk_offline %>`'s banner (put it in the layout)
and cancels links to other pages; events `monk-offline:offline` /
`monk-offline:online`. `sw.js` answers a page load that fails with
`offline.html`. Monk's docs/guides/offline.md has the rest.

**Test:** `test/pwa_test.rb` requests the manifest, its icons, `sw.js`
and `offline.html`, and checks a page links them.

**Pitfalls:**
- `sw.js`'s `fetch` handler takes failed page loads only. Never store
  Monk::Live's resync (a fetch), a redirect, a non-GET or `/_monk/`;
  caching more (a page to read offline) follows docs/guides/offline.md,
  level 1, including clearing it at sign-out. Code that deletes caches
  keeps `monk-offline` and `monk-pwa-app-windows`.
- When the app's own `fetch` fails with a network error, dispatch
  `monk-offline:check` on `document`.
- `offline.html` must work alone: styles and script inline.
- Link the manifest and `sw.js` by their plain paths, never with
  `asset_path`: a service worker's URL is its identity.
- Service workers need https or localhost.
