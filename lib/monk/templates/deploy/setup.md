## deploy

The app on one Linux host with Docker (any provider): `compose.yaml` runs
this app's image as `web`, and as `ws` and `jobs` with those modules,
beside Postgres and Redis with theirs, and Caddy in front for HTTPS.
Every module added later adds its own services and settings. A tested
deploy on Hetzner Cloud with Brevo for mail, step by step:
`docs/guides/deploy-hetzner.md` in the monk repo.

### Before the first deploy

1. In `.env.production.example`, set `PUBLIC_URL` and `SITE_ADDRESS`
   (its host), and anything else still on `example.com`. Keep secrets
   out of it: they're made on the host.
2. Commit, `Gemfile.lock` included. Its `PLATFORMS` must list the host's
   (`x86_64-linux` or `aarch64-linux`): a lockfile made before Ruby 4's
   Bundler may list only your machine's; then
   `bundle lock --add-platform x86_64-linux aarch64-linux`.
3. The host: Docker with Compose, ports 22, 80 and 443 open, and a DNS
   record pointing the name at it, so Caddy can get the certificate.

### On the host

```bash
bin/deploy_env                              # .env.production, with the secrets
docker compose build
docker compose up -d --wait postgres        # with postgres
docker compose run --rm web bin/setup_db    # with postgres, every deploy
docker compose up -d
```

`bin/deploy_env` writes `.env.production` from the example the first
time, and fills in every empty secret: `AUTH_SECRET`, the database
password, the push key pair. Run it again after adding a module.

### Keep

- **`.env.production` is part of every backup.** Restoring a database
  under a new `AUTH_SECRET` signs everybody out, under a new VAPID pair
  ends every push subscription. Save it beside each dump.
- **Logs** go to `log/<MONK_ENV>.log` in the `log` volume, not to
  `docker compose logs`:
  `docker compose exec web tail -f log/production.log`.

### Check it works

`https://<SITE_ADDRESS>` answers with a certificate, `http://` redirects
to it, and `docker compose ps` shows every service running. With mail on
`log://`, a login link is in the log.
