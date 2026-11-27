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
- `public/offline.html`: the page shown when a page can't load offline;
- `config/pwa.rb`: `Monk::Pwa.configure`;
- `test/pwa_test.rb`.

There's nothing else to wire: the layout's `<%= monk_head %>` links the
manifest, the theme colour and the iOS icon, and loads Monk's
`/_monk/pwa/register.js`, which registers `/sw.js` for the whole site,
and `/_monk/pwa/offline.js`, which says when the page is offline
([`offline.md`](offline.md)). Add `<%= monk_offline %>` to the layout for
its banner.

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

It steps in for **page loads only, and only when they fail**: no
network, or the proxy answering for an app that's down (502, 503, 504).
Then it shows `public/offline.html`, stored in a cache named
`monk-offline` when the worker installs and refreshed once per start of
the worker ([`offline.md`](offline.md#level-0-what-monk-does)). Every
other request, and every answer that came, goes through untouched and is
never stored: it never answers Live's resync (a fetch of the page, not a
page load) from a cache, never caches a login redirect, and never touches
`/_monk/` paths. Storing pages to read offline is the app's to add:
keep those requests out of it ([`offline.md`](offline.md#level-1-a-page-stored-for-offline)).

The end of the file shows web push messages as notifications; it does
nothing until push is set up ([`push.md`](push.md)). For their clicks,
each page running as the installed app (`display-mode: standalone`)
tells the worker so, through `register.js`, and the worker keeps the
note in a cache named `monk-pwa-app-windows`. Caching code that deletes
the caches it doesn't know should keep that one and `monk-offline`.

`register.js` reports on `document`: `monk-pwa:registered` (`{ scope }`),
`monk-pwa:unsupported` (`{ reason: "no-service-worker" | "insecure" }`),
`monk-pwa:failed` (`{ message }`), `monk-pwa:installable`,
`monk-pwa:installed` and, with auth, `monk-pwa:own-session` (`{ status }`,
[`auth.md`](auth.md#the-installed-iphone-apps-own-session)).

## Helping people install

Nothing tells a person they can install the app, and on iOS there's no
prompt at all: Add to Home Screen is in Safari's Share menu. Monk helps
in two ways.

**Where the page runs.** `register.js` sets, on `<html>`:

| Attribute | Value |
|---|---|
| `data-pwa-standalone` | `"true"` in the installed app, `"false"` in a tab |
| `data-pwa-platform` | `"ios"`, `"android"` or `"other"` (an iPad reporting itself as a Mac counts as iOS) |
| `data-pwa-installable` | present once Chrome offered to install (`beforeinstallprompt`) |
| `data-pwa-in-app` | present in a chat or social app's built-in browser, guessed from the user agent (Instagram, Facebook, LinkedIn, Line, TikTok, Telegram; WhatsApp's on iOS can't be told from Safari) |

so CSS can show the right thing with no JavaScript of the app's own:

```css
.install-hint { display: none; }
[data-pwa-platform="ios"][data-pwa-standalone="false"] .install-hint { display: block; }
```

**A banner.** `<%= monk_install %>`, in the layout or a page, renders a
banner with a button, and an iOS sheet (a `<dialog>`: Tap Share, then Add
to Home Screen, with iOS's two icons). It's hidden until `register.js`
shows it: on iOS, where the button opens the sheet, and on Android once
Chrome offered its prompt, which the button opens. Never in the installed
app, nor on a desktop. The markup has BEM classes (`monk-install`,
`__text`, `__button`, `__sheet`, `__steps`, `__step`, `__icon`,
`__close`) and no styles: the app styles it. Every text can be
overridden, for another language say:

```erb
<%= monk_install text: "Installa l'app.", button: "Installa", share: "Tocca Condividi",
                 add: "poi Aggiungi alla schermata Home", close: "OK" %>
```

## Leaving a chat app's built-in browser

A page opened from a link in WhatsApp or Instagram often opens in that
app's built-in browser, which can't install the app. Signing in works
there, with the code ([`auth.md`](auth.md#signing-in-with-a-code)), so
leaving it only matters for installing. Monk has no helper for it, but
`data-pwa-in-app` tells the page where it is, and a button can try to
open the page in the real browser:

```erb
<p class="open-in-browser">
  To install the app, open this page in your browser.
  <a data-open-browser href="#">Open in browser</a>
  <span class="open-in-browser__ios">Or tap ••• and choose Open in Safari.</span>
</p>
```

```css
.open-in-browser { display: none; }
[data-pwa-in-app] .open-in-browser { display: block; }
[data-pwa-platform="android"] .open-in-browser__ios { display: none; }
```

```js
// public/js/app.js
document.addEventListener("click", (event) => {
  const link = event.target.closest("[data-open-browser]");
  if (!link) return;
  event.preventDefault();
  const { host, pathname, search } = location;
  location.href = document.documentElement.dataset.pwaPlatform === "android"
    ? `intent://${host}${pathname}${search}#Intent;scheme=https;end`
    : `x-safari-https://${host}${pathname}${search}`;
});
```

- **Android:** the `intent://` URL asks Android to open the page in the
  default browser; it works from the common built-in browsers.
- **iOS:** `x-safari-https://` isn't documented by Apple, and some apps
  block it, so keep the "Tap ••• → Open in Safari" text beside the
  button.
- **WhatsApp on iOS** can't be detected: `data-pwa-in-app` stays unset
  there, and the person sees what Safari would show.

## https

Service workers need https, or `localhost`. A phone opening the dev
server at `http://192.168.x.x` gets none, and can't install the app. To
try it on a phone before deploying, expose the dev server through an
https tunnel.

## Checking it

`test/pwa_test.rb` requests the manifest, its icons, `sw.js` and
`offline.html`, and checks a page links them. By hand, in Chrome: DevTools › Application ›
Manifest lists no errors, Service workers shows `/sw.js` activated, and
the address bar offers to install the app. Monk's own suite does the same
in headless Chrome (`test/pwa_browser_test.rb`), from the files exactly
as `monk add pwa` writes them.
