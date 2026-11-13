# Installable app — `Monk::Pwa`

Makes the app installable: on a phone's Home Screen, or as a desktop app
from the browser's address bar, opening in its own window. On iOS it's
also what web push needs: notifications only reach an app added to the
Home Screen ([`push.md`](push.md)).

```
monk add pwa
```

needs no other module, and writes:

- `public/manifest.webmanifest`: the app's name (from its directory),
  colours, start URL, display mode and icons;
- `public/icons/`: placeholder icons, 192 and 512 px, a maskable 512 px
  one, and a 180 px `apple-touch-icon.png` for iOS;
- `public/sw.js`: the service worker;
- `config/pwa.rb`: `Monk::Pwa.configure`;
- `test/pwa_test.rb`.

There's nothing else to wire: the layout's `<%= monk_head %>` links the
manifest, the theme colour and the iOS icon, and loads Monk's
`/_monk/pwa/register.js`, which registers `/sw.js` for the whole site.

## Make it yours

- **The name.** `name` (on the install prompt and the splash screen) and
  `short_name` (under the icon) start as the app's directory name. Set the
  ones people should see.
- **The icons.** Replace each placeholder with an image of the same size.
  The maskable one keeps its content inside the middle 80%: Android crops
  it to a circle or a rounded square.
- **The colours.** `theme_color` colours the title bar, and Monk's
  `theme-color` meta reads it from the manifest; `background_color` is the
  splash screen's.

## Checked at boot

`Monk::Pwa.configure` reads the manifest and fails the boot
(`Monk::Pwa::InvalidManifestError`) unless a browser could install the app
from it:

- valid JSON, with `name` and `short_name` (and no `{{app}}` left in them);
- a `start_url`, and `display` one of `standalone`, `fullscreen`,
  `minimal-ui` (`browser` isn't installable);
- a 192×192 and a 512×512 icon whose `purpose` includes `any`;
- every local file it names, `public/sw.js` and
  `public/icons/apple-touch-icon.png` (or `configure(apple_touch_icon:)`).

## The service worker

`public/sw.js` is the app's own file, at the root, because a service
worker only controls pages under its own path. It's linked by its plain
path, never `asset_path`: its URL is its identity, so a `?v=` would make
every deploy a new registration. It's served `must-revalidate`, and
registered with `updateViaCache: "none"`, so an edited `sw.js` is picked
up on the next page load and takes over open pages at once.

It has **no `fetch` handler**, on purpose: every request goes to the
network as if there were no service worker. So it never answers Live's
resync (a refetch of the page) from a cache, never caches a login
redirect, and never touches `/_monk/` paths. An offline page or caching
needs one: keep those requests out of it.

The end of the file shows web push messages as notifications; it does
nothing until push is set up ([`push.md`](push.md)).

`register.js` reports on `document`: `monk-pwa:registered` (`{ scope }`),
`monk-pwa:unsupported` (`{ reason: "no-service-worker" | "insecure" }`)
and `monk-pwa:failed` (`{ message }`).

## https

Service workers need https, or `localhost`. A phone opening the dev
server at `http://192.168.x.x` gets none, and can't install the app. To
try it on a phone before deploying, expose the dev server through an
https tunnel.

## Checking it

`test/pwa_test.rb` requests the manifest, its icons and `sw.js`, and
checks a page links them. By hand, in Chrome: DevTools › Application ›
Manifest lists no errors, Service workers shows `/sw.js` activated, and
the address bar offers to install the app. Monk's own suite does the same
in headless Chrome (`test/pwa_browser_test.rb`), from the files exactly
as `monk add pwa` writes them.
