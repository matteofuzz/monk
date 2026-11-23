# Deploying on Hetzner Cloud, with Brevo for mail

One Monk app on one Hetzner Cloud server, with mail through Brevo: every
step, from the accounts to backups. This is the deploy run for the first
Monk app on a real host (2026-11-19, 2026-11-20). That app has web,
WebSocket, Live, presence, jobs, auth, PWA and push on Postgres. Checked
there:

- every container running and no pending migration;
- HTTPS with the http redirect;
- a login link sent by `bin/jobs`, both to the log and as real mail
  (DKIM and DMARC passing);
- the `/ws` handshake;
- push on an iPhone;
- a snapshot restored onto a new server, and a database dump loaded into
  a fresh one.

The stack itself is `monk add deploy`'s ([`deploying.md`, section
4](deploying.md#4-a-single-vps-docker-compose--caddy)), and runs on any Linux
host with Docker. This guide adds what's Hetzner's and Brevo's. The commands
use `shop` for the app and `shop.example.com` for its address: use your own.

## 1. Accounts, once

**Hetzner Cloud.**

1. Make a project for the app in the console.
2. In the project, under Security › API tokens, make a **Read & Write**
   token.
3. Install the CLI (`brew install hcloud`) and give it the token. Run this
   in your own terminal, since it asks for the token:

   ```bash
   hcloud context create shop
   ```

   A context is one project. `hcloud context use shop`, or
   `HCLOUD_CONTEXT=shop` in a script, makes sure a command never touches
   another project.
4. Add an SSH key to the project:

   ```bash
   hcloud ssh-key create --name me --public-key-from-file ~/.ssh/id_ed25519.pub
   ```

**A domain** (optional). Keep its DNS zone in Hetzner (Console › DNS), so
the A record can be set with `hcloud` too. Use hyphens, not underscores,
in host names: `shop-staging.example.com`. Without a domain,
`<ip>.sslip.io` needs no DNS at all: it resolves to the IP it names, and
Caddy gets a real certificate for it. Its URL changes with the IP,
though, so a restore onto a new server moves the app, and push
subscriptions made at the old address stop working.

**Brevo**, for mail ([`mail.md`](mail.md#provider-examples)):

1. Sign up, then authenticate your domain (Senders, Domains & Dedicated
   IPs). Brevo shows DNS records to add: the DKIM key, its own code, and
   a DMARC record if the domain has none. Add them to the zone. Brevo
   checks them within minutes.
2. On the SMTP & API page, make one **SMTP key** per app. It isn't the
   API key. The SMTP login on that page looks like
   `8f1a2b001@smtp-brevo.com`.
3. Send from an address on the domain you authenticated
   (`shop@example.com`), never on the app's own subdomain
   (`shop.example.com`), which Brevo hasn't authenticated.

The free plan sends 300 mails a day, and each login link is one mail.

## 2. The app

```bash
monk add deploy
```

In `.env.production.example`, set `PUBLIC_URL=https://shop.example.com`
and `SITE_ADDRESS=shop.example.com` (or the sslip.io name, once the server
has its IP). Put no secrets in it: `bin/deploy_env` makes them on the
server.

Check `Gemfile.lock`'s `PLATFORMS`. It must list `x86_64-linux`, the
platform of Hetzner's `cx` servers. A lockfile made with Ruby 4's Bundler
lists every platform, but an older lockfile keeps only the platforms it
started with. If it's missing, run:

```bash
bundle lock --add-platform x86_64-linux aarch64-linux
```

`monkrb` must come from RubyGems or git, not a `path:`, since the image
can't see outside the app. Commit: the deploy ships what's committed.

## 3. The server

**The firewall**: SSH, HTTP, HTTPS, and HTTP/3 on UDP 443.

```bash
cat > firewall.json <<'JSON'
[
  {"direction":"in","protocol":"tcp","port":"22","source_ips":["0.0.0.0/0","::/0"]},
  {"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"]},
  {"direction":"in","protocol":"tcp","port":"443","source_ips":["0.0.0.0/0","::/0"]},
  {"direction":"in","protocol":"udp","port":"443","source_ips":["0.0.0.0/0","::/0"]}
]
JSON
hcloud firewall create --name shop --rules-file firewall.json
```

**First boot** (`cloud-init.yaml`):
- Docker and Compose from Ubuntu's packages;
- 2 GB of swap, as headroom for the gem build and load spikes;
- container logs capped, so they can't fill the disk.

```yaml
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - docker-buildx
write_files:
  - path: /etc/docker/daemon.json
    content: |
      {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}
runcmd:
  - fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  - echo '/swapfile none swap sw 0 0' >> /etc/fstab
  - sysctl -w vm.swappiness=10 && echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  - systemctl enable --now docker
  - mkdir -p /opt/shop
```

**The server**: a `cx23` has 2 shared vCPUs, 4 GB of RAM and a 40 GB
disk. It costs about €6.70 a month plus €0.61 for the IPv4 (VAT included,
2026-11-19), billed by the hour.

```bash
hcloud server create --name shop --type cx23 --location hel1 --image ubuntu-24.04 \
  --ssh-key me --firewall shop --user-data-from-file cloud-init.yaml
hcloud server ip shop
ssh root@$(hcloud server ip shop) 'cloud-init status --wait'
```

A new server may reuse an IP you've connected to before. If `ssh`
refuses its host key, run `ssh-keygen -R <ip>` first.

## 4. DNS

Point the name at the server, with a short TTL so a move takes effect
fast:

```bash
ip=$(hcloud server ip shop)
hcloud zone rrset set-records --record "$ip" example.com shop A
hcloud zone rrset change-ttl --ttl 300 example.com shop A
dig +short A shop.example.com @1.1.1.1      # until it prints $ip
```

Wait until a public resolver sees it before starting Caddy. Caddy asks
Let's Encrypt for the certificate as soon as it starts, and keeps
retrying while the name doesn't resolve, with longer and longer pauses.

## 5. Shipping the code

The code goes over SSH and the image is built on the server, so there's
no registry. `.env.production` stays on the server across deploys.

```bash
ip=$(hcloud server ip shop)
git archive --format=tar HEAD | ssh root@$ip '
  set -e
  rm -rf /opt/shop.new && mkdir -p /opt/shop.new
  tar -x -C /opt/shop.new
  [ -f /opt/shop/.env.production ] && cp -p /opt/shop/.env.production /opt/shop.new/
  rm -rf /opt/shop.old && mv /opt/shop /opt/shop.old && mv /opt/shop.new /opt/shop && rm -rf /opt/shop.old'
```

**The first time**, on the server (`ssh root@$ip`, then `cd /opt/shop`):

```bash
bin/deploy_env                              # .env.production: the secrets, the push keys
docker compose build --pull
docker compose up -d --wait postgres
docker compose run --rm web bin/setup_db
docker compose up -d
```

`bin/deploy_env` writes `.env.production` from the example and fills in
every empty secret, here on the server, so they never travel. It also
lists what's still a placeholder. Compose won't even build without the
file, so it comes first.

**Every later deploy**: the `git archive` above, then:

```bash
docker compose build --pull
docker compose run --rm web bin/setup_db
docker compose up -d --remove-orphans
docker image prune -f
```

`up -d` replaces only the containers whose image or settings changed.
`web` and `jobs` get 35 s to finish what they're doing on `TERM`. While
`ws` restarts, open pages reconnect, and presence carries them over the
gap ([`presence.md`](presence.md)).

## 6. Mail

Until mail is set up, keep `MAIL_URL=log://`. Every message, login links
included, then goes to the log:

```bash
docker compose exec web grep -o 'https://[^ ]*/auth/callback/[^ ]*' log/production.log | tail -1
```

Then switch to Brevo, on the server. Percent-encode the login's `@` as
`%40`. Single quotes keep Compose from expanding a `$`. Read the key from
the keyboard, so it never lands in a command line or your shell history:

```bash
cd /opt/shop
read -rsp "Brevo SMTP key: " key; echo
grep -v -e '^MAIL_URL=' -e '^MAIL_FROM=' .env.production > .env.production.tmp
printf "MAIL_URL='smtp://8f1a2b001%%40smtp-brevo.com:%s@smtp-relay.brevo.com:587'\n" "$key" >> .env.production.tmp
echo 'MAIL_FROM="shop <shop@example.com>"' >> .env.production.tmp
mv .env.production.tmp .env.production && chmod 600 .env.production
unset key
docker compose up -d --force-recreate web jobs
```

Brevo's SMTP keys are letters, digits and dashes, so they need no
encoding. Another provider's password might.

Check that the login works, without sending anything:

```bash
docker compose exec -T web bundle exec ruby -e 'require "./config/settings"; require "./config/mail"; puts Monk::Mail.check'
```

It answers `connected (STARTTLS), logged in as ...`, or says what failed
(see [`mail.md`](mail.md#checking-mail_url)).

`jobs` is the process that sends mail. If nothing arrives, check
`docker compose logs --tail 50 jobs` and the log file, then the
recipient's spam folder.

## 7. Checking it

Boot refuses a `PUBLIC_URL`, `LIVE_WS_URL` or `AUTH_SECRET` that's
present but wrong ([`settings.md`](settings.md#values-refused-at-boot)),
so a service that keeps restarting says why in
`docker compose logs`. The rest, check from your machine:

```bash
url=https://shop.example.com
ssh root@$ip 'cd /opt/shop && docker compose ps --format "{{.Service}} {{.State}}"'   # all running
ssh root@$ip 'cd /opt/shop && docker compose exec -T web bin/migrate status'         # nothing pending
curl -s -o /dev/null -w '%{http_code}\n' $url/                                       # 200
curl -s -o /dev/null -w '%{http_code}\n' http://shop.example.com/                    # 308, to https
curl -s -o /dev/null -w '%{http_code}\n' --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H "Origin: $url" --max-time 5 $url/ws                                             # 101, with websocket
```

**With auth:** log in through the page. With `log://`, the link is in the
log, which proves `jobs` runs.

**With PWA:** `/manifest.webmanifest` and `/sw.js` answer 200.

**With push:** the page's `monk-push-key` meta equals the server's
`VAPID_PUBLIC_KEY`.

## 8. Backups

**`.env.production` is part of every backup.** Restoring the data under
different secrets breaks it:
- a new `AUTH_SECRET` leaves every session stuck;
- a new VAPID pair ends every push subscription;
- losing a key the app encrypts with makes that data unreadable.

Copy the file next to every dump.

**A dump**, from your machine:

```bash
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p backups
(umask 077
 ssh root@$ip "cd /opt/shop && docker compose exec -T postgres sh -c 'pg_dump -U \"\$POSTGRES_USER\" \"\$POSTGRES_DB\"'" \
   | gzip > backups/shop-$stamp.sql.gz
 ssh root@$ip 'cat /opt/shop/.env.production' > backups/shop-$stamp.env)
```

**A snapshot** saves the whole server: the OS, the code, the env file,
the database and Caddy's certificates. Stop the app and shut the server
down first, so Postgres is consistent:

```bash
ssh root@$ip 'cd /opt/shop && docker compose stop'
hcloud server shutdown shop        # then wait for: hcloud server describe shop -o format='{{.Status}}' == off
hcloud server create-image shop --type snapshot --description "shop $(date +%F)"
hcloud server poweron shop         # the containers come back by themselves (restart: unless-stopped)
```

To stop paying for the server, delete it after the snapshot with
`hcloud server delete shop`. A snapshot then costs about €0.02 per GB a
month.

**Restoring a snapshot** onto a new server (no cloud-init: the snapshot
has it all):

```bash
hcloud image list -t snapshot
hcloud server create --name shop --type cx23 --location hel1 --image <snapshot id> \
  --ssh-key me --firewall shop
```

Point DNS at the new IP (section 4). With sslip.io, `PUBLIC_URL` and
`SITE_ADDRESS` change too. Then run `docker compose up -d --force-recreate`
on the server. A snapshot only restores onto a server type with at least
its disk size.

**Loading a dump into a fresh server.** First ship the code (section 5),
but put the saved env file in place before the first build, instead of
running `bin/deploy_env`. Pipe it over stdin, as
`ssh root@$ip 'umask 077; cat > /opt/shop/.env.production' < backups/shop-<stamp>.env`,
so it never shows up in a command line. Then:

```bash
docker compose up -d --wait postgres
gunzip -c shop-<stamp>.sql.gz | docker compose exec -T postgres sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"'
docker compose run --rm web bin/setup_db     # migrations newer than the dump
docker compose up -d
```

## 9. Costs and capacity

| | |
|---|---|
| `cx23` server | about €7.31 a month, IPv4 included, billed by the hour |
| Snapshot | about €0.02 per GB a month |
| Brevo free plan | 300 mails a day, so about 300 logins and invitations a day: likely the first limit |

These are estimates for a `cx23`, made for the first app and not
load-tested on it. They assume 15–25% of people online at once, with one
WebSocket per open page:
- **Comfortable:** 500–1,000 registered people, that is 100–250 online.
- **Probably fine:** up to about 5,000 registered (about 1,000 online),
  as long as Brevo's daily cap covers the logins.
- **Beyond that:** a dedicated-CPU server and `WS_PROCESSES=2`
  ([`websocket.md`](websocket.md#several-processes)).

## 10. Day to day

```bash
ssh root@$ip
cd /opt/shop
docker compose ps
docker compose exec web tail -f log/production.log   # Monk's log, not `docker compose logs`
docker compose logs --tail 50 jobs                   # a crash's output
docker compose run --rm web bin/console
docker stats
```

Ubuntu installs its security updates by itself (`unattended-upgrades`).
A kernel update needs a reboot, and the containers come back by
themselves.
