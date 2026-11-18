## pwa

The app can be installed: on a phone's Home Screen, or as a desktop app
from the browser's address bar. On iOS, web push (monk add push) only
reaches an app installed this way. Nothing to start: the files are in
`public/`, and `config/pwa.rb` checks them at boot.

### Make it yours

- `public/manifest.webmanifest`: `name` (on the install prompt and the
  splash screen) and `short_name` (under the icon) start as `{{app}}`; set
  the name people should see. `theme_color` colours the title bar and the
  `theme-color` meta, `background_color` the splash screen.
- `public/icons/`: placeholders. Replace each with an image of the same
  size: `icon-192.png`, `icon-512.png`, `icon-maskable-512.png` (its
  content inside the middle 80%, since Android crops it to a circle or a
  rounded square) and `apple-touch-icon.png` (180×180, iOS).

### Before production

Service workers need https (or localhost): a phone opening the dev server
at `http://192.168.x.x` gets none. To try installing on a phone before
deploying, expose the dev server through an https tunnel.

### Check it works

1. `bundle exec rake test` runs `test/pwa_test.rb`: the manifest, its
   icons and `sw.js` are served, and pages link them.
2. By hand, in Chrome: open http://localhost:9292, then DevTools ›
   Application › Manifest lists no errors, and Service workers shows
   `/sw.js` activated. The address bar offers to install the app.
