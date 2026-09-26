# Transactional mail providers for `Monk::Mail` — preset analysis

Research only: which HTTPS API "presets" the planned `Monk::Mail` module
should ship next to its SMTP transport. Nothing here changes `monk`
itself. The module is opt-in and zero-dependency. It will have one
`Net::SMTP` transport and 2–3 presets of about 15 lines each. A preset
maps `{from, to, subject, text, html, reply_to}` onto one provider's
HTTPS API with stdlib `Net::HTTP`, and it is picked by a single env var
(`MAIL_URL=resend://KEY`, `postmark://TOKEN`, …). This doc answers
*which* providers get a preset. It weighs price and popularity, and
favours EU companies and EU data residency. All provider facts were
checked on **2026-09-26** against the providers' own pricing, API and
legal pages, unless a claim is marked *secondary* or *unverified*.

## 1. What a preset has to fit

These are the constraints that decide whether a provider gets a preset
or is left to the SMTP transport. They come from Monk's shape (see
`docs/deployment-options.md` §4), not from any one provider.

| # | Constraint | Why |
|---|---|---|
| P1 | **One HTTPS POST, a static auth header, a JSON body** | Anything that needs request signing (AWS SigV4) or multipart encoding is more than 15 lines and more than zero dependencies |
| P2 | **Credentials fit in one URL** | `MAIL_URL=scheme://SECRET[@host]`. A provider that also needs a project ID, a region or a key pair still fits (`user:pass@host`), but each extra part is one more thing to explain |
| P3 | **Built per call inside a worker Ractor** | No global client object. `Net::HTTP.start` per send, the same as `PG::Connection` is per Ractor |
| P4 | **Fast and bounded** | Every send blocks a pool slot (no job queue), so a single round-trip HTTPS call with a tight timeout beats a multi-round-trip SMTP conversation |
| P5 | **SMTP is the universal fallback** | Every provider below offers SMTP, so no provider is *unreachable*. A preset is a convenience, not a requirement |

## 2. The providers at a glance

"EU data" means data stored and processed in the EU *by default*. "opt-in"
means the provider offers an EU region, but you must choose it and send
through its separate endpoint.

### 2.1 Company, residency, free tier, price

| Provider | HQ / entity | EU data | Free tier | Cheapest paid | ≈ per 1k at 10k/mo | ≈ per 1k at 50k/mo |
|---|---|---|---|---|---|---|
| **Brevo** | France (Sendinblue SAS, Paris) | **Yes, default, all plans** (FR/DE + GCP Belgium) | 300/day, permanent; Brevo logo on free | Starter $9 (€7)/mo from 5,000 emails | not published on primary page | not published on primary page |
| **Mailjet** | France, part of Sinch (Sweden) | **Yes, default** (GCP Frankfurt + Saint-Ghislain, BE) | 200/day, 6,000/mo; Mailjet logo | Essential $19/mo, 15,000 | $1.90 (paying for 15k) | custom/unpublished |
| **Scaleway TEM** | France | **Yes, default** (`fr-par` only) | 300/mo | Pay-as-you-go €0.25/1k; Scale €80/mo for 100k | ≈ €0.24 | ≈ €0.25 |
| **Lettermint** | Netherlands (Lettermint B.V.) | **Yes, default**, own EU infra, no US hyperscalers | 300/mo | Starter €10/mo, 10,000 | €1.00 | €0.80 (€40/mo) |
| **Sweego** | France (MINDBAZ) | **Yes, default** (OVH, Scaleway, Alter Way, all FR) | 100/day | Individual €10/mo, "20K or 50K" | €1.00 (paying for 20k) | ambiguous, see §3.5 |
| **MailPace** | UK | **Yes**, "hosted in the European Union" | 100/mo, on request | $10/mo, 10,000 | $1.00 | unpublished (slider) |
| **Mailgun** | US, part of Sinch | opt-in EU region, per domain, all plans | 100/day | Basic $15/mo, 10,000 | $1.50 | $0.70 (Foundation $35/50k) |
| **SMTP2GO** | New Zealand | opt-in in practice (Amsterdam DC; EU/UK signups auto-assigned) | 1,000/mo | Starter $10/mo, 10,000 | $1.00 | $1.00 (overage $1/1k) |
| **MailerSend** | US entity (MailerSend, Inc., NY) | **Yes, default** (GCP Belgium) | 500/mo | Hobby $5.60/mo, 5,000 | unverified | unverified |
| **Resend** | US (Plus Five Five, Inc., SF) | **No**. Can *send* from `eu-west-1`, but all account data stays in the US | 3,000/mo, 100/day | Pro $20/mo, 50,000 | $2.00 (paying for 50k) | **$0.40** |
| **Postmark** | US (ActiveCampaign) | **No**, and "no plans to add servers in the EU" | 100/mo, permanent | Basic $15/mo, 10,000 | $1.50 | ≈ $1.74 (Basic + $1.80/1k overage) |
| **Amazon SES** | US | opt-in: pick an EU region | $200 AWS credits for 6 months (new accounts); sandbox 200/24h | à-la-carte $0.10/1k, no plan | **$0.10** | **$0.10** |
| **SendGrid** | US (Twilio) | Pro plan or higher only, with a dedicated EU IP | **None**. 60-day trial, 100/day | Essentials $19.95/mo, 50,000 | $2.00 (paying for 50k) | $0.40 |
| **Mailtrap** | US (Railsware Products Studio LLC, DE) | **No** (EU residency "planned") | 4,000/mo, 150/day | Basic $15/mo, 10,000 | $1.50 | $0.40 ($20/50k as listed) |
| **Bird (ex-SparkPost)** | not verified | not verified | 1,000/mo | from $15/mo, 50k–100k | — | $0.30 |
| **Elastic Email** | "Elastic Email Inc." | not verified | 3,000/mo (as listed) | Starter $19/mo, 50,000 | — | ≈ $0.38 |

"Paying for Nk" means the cheapest plan includes more than 10k, so the
effective rate at 10k is the plan price ÷ 10.

### 2.2 HTTPS API shape for a single send

| Provider | Endpoint (EU if separate) | Auth header | from / to / subject / text / html / reply-to | Raw MIME over HTTPS | Fits a ~15-line preset? |
|---|---|---|---|---|---|
| **Resend** | `POST https://api.resend.com/emails` | `Authorization: Bearer re_…` | `from` "Name \<a@b\>" / `to` string or array / `subject` / `text` / `html` / `reply_to` string or array | no | **Yes**. The field names *are* Monk's message fields |
| **Lettermint** | `POST https://api.lettermint.co/v1/send` | `x-lettermint-token: …` | `from` string / `to` **string[]** / `subject` / `text` / `html` / `reply_to` **string[]** | no (not documented) | **Yes**. Same shape as Resend, except `to` and `reply_to` are always arrays |
| **Postmark** | `POST https://api.postmarkapp.com/email` | `X-Postmark-Server-Token: …` | `From` / `To` comma-separated string / `Subject` / `TextBody` / `HtmlBody` / `ReplyTo` (+ `MessageStream`) | no (not in API docs) | **Yes**. PascalCase renames only |
| **MailPace** | `POST https://app.mailpace.com/api/v1/send` | `MailPace-Server-Token: …` | `from` / `to` / `subject` / `textbody` / `htmlbody` / `replyto` | no | **Yes** |
| **Brevo** | `POST https://api.brevo.com/v3/smtp/email` | `api-key: …` | `sender` **{email,name}** / `to` **[{email,name}]** / `subject` / `textContent` / `htmlContent` / `replyTo` **{email,name}** | no | **Yes**. Needs a small "Name \<addr\>" → `{name:, email:}` helper |
| **Mailjet** | `POST https://api.mailjet.com/v3.1/send` | HTTP Basic `KEY:SECRET` | `{"Messages":[{ From {Email,Name}, To [{Email}], Subject, TextPart, HTMLPart, ReplyTo }]}` | no | **Yes**, but needs a key pair and a `Messages` wrapper. `ReplyTo` shape unverified |
| **MailerSend** | `POST https://api.mailersend.com/v1/email` | API key header (Bearer format not confirmed on the fetched page) | `from` {email,name} / `to` [{email,name}] / `subject` / `text` / `html` / `reply_to` {email,name} | no | **Yes**, same shape as Brevo with snake_case |
| **Mailtrap** | `POST https://send.api.mailtrap.io/api/send` | `Api-Token: …` or `Authorization: Bearer …` | `from` {email,name} / `to` [{email}] / `subject` / `text` / `html` / `reply_to` {email,name} | no | **Yes** |
| **SMTP2GO** | `POST https://api.smtp2go.com/v3/email/send` (EU: `eu-api.smtp2go.com`) | `X-Smtp2go-Api-Key: …` | `sender` "Name \<a@b\>" / `to` string[] / `subject` / `text_body` / `html_body` / Reply-To via `custom_headers` | **yes** (`send-mime-email`) | **Yes** |
| **Sweego** | `POST https://api.sweego.io/send` | `Api-Key: …` | `channel:"email"`, `provider:"sweego"`, `recipients` [{email,name}] / `from` {email,name} / `subject` / `message-txt` / `message-html` / Reply-To via `headers` map (max 5) | unverified | **Yes**, with two fixed constant fields |
| **Scaleway TEM** | `POST https://api.scaleway.com/transactional-email/v1alpha1/regions/fr-par/emails` | `X-Auth-Token: …` | `from` {email,name} / `to` [{email,name}] / `subject` / `text` / `html` / **`project_id` required** / Reply-To only via `additional_headers` [{key,value}] | no | **Yes**, but needs a project ID and uses a `v1alpha1` API, so `MAIL_URL=scaleway://PROJECT_ID:KEY@fr-par` |
| **SendGrid** | `POST https://api.sendgrid.com/v3/mail/send` (EU: `api.eu.sendgrid.com`) | `Authorization: Bearer …` | `personalizations:[{to:[{email}]}]` / `from` {email} / `subject` / `content:[{type,value}]` / `reply_to` {email} | no | Technically yes, but the nesting is the heaviest of any JSON API here |
| **Mailgun** | `POST https://api.mailgun.net/v3/{domain}/messages` (EU: `api.eu.mailgun.net`) | HTTP Basic `api:KEY` | **`multipart/form-data`**: `from` / `to` comma-sep / `subject` / `text` / `html` / `h:Reply-To` | **yes** (`/messages.mime`) | **Borderline**. Not JSON, and the sending domain goes in the path. `Net::HTTP#set_form` can do it, but it breaks the "one JSON body" pattern |
| **Amazon SES v2** | `POST https://email.{region}.amazonaws.com/v2/email/outbound-emails` | **AWS SigV4 signature** | `FromEmailAddress` / `Destination.ToAddresses[]` / `Content.Simple.Subject.Data` / `…Body.Text.Data` / `…Body.Html.Data` / `ReplyToAddresses[]` | **yes** (`Content.Raw`) | **No**. SigV4 canonical-request signing alone is longer than the whole preset budget. Use SES SMTP |

### 2.3 SMTP relay (what the SMTP transport covers anyway)

| Provider | Host | Ports | Username / password |
|---|---|---|---|
| Brevo | `smtp-relay.brevo.com` | 587, 2525 (STARTTLS), 465 (TLS) | SMTP login / SMTP key (not the API key) |
| Mailjet | `in-v3.mailjet.com` | 25, 80, 465, 587, 588, 2525 | API key / secret key |
| Scaleway TEM | `smtp.tem.scaleway.com` | 25, 587, 2587, 465, 2465 | project ID / API secret key |
| Lettermint | `smtp.lettermint.co` | 587, 465, 25, 2525, 2465, 2587 | `lettermint` / project API token |
| Sweego | from the dashboard (unverified) | unverified | SMTP login / password |
| MailPace | `smtp.mailpace.com` | 25, 587, 2525 (STARTTLS), 465 (TLS) | API token / API token |
| Mailgun | `smtp.mailgun.org` (EU: `smtp.eu.mailgun.org`) | 25, 465, 587, 2525 | per-domain SMTP credentials |
| SMTP2GO | `mail.smtp2go.com` (EU: `mail-eu.smtp2go.com`, EU-only: `mail-eu2.smtp2go.com`) | 25, 2525, 8025, 587, 80, 465, 8465, 443 | SMTP user / password |
| MailerSend | `smtp.mailersend.net` | 587, 2525 | SMTP user / password |
| Resend | `smtp.resend.com` | 25, 587, 2587 (STARTTLS), 465, 2465 (TLS) | `resend` / API key |
| Postmark | `smtp.postmarkapp.com` (broadcast: `smtp-broadcasts.postmarkapp.com`) | 25, 2525, 587 | Server API token as both, plus `X-PM-Message-Stream` header |
| Amazon SES | `email-smtp.{region}.amazonaws.com`; EU: `eu-west-1`, `eu-west-2`, `eu-west-3`, `eu-central-1`, `eu-north-1` (no SMTP in Milan or Zurich) | 25, 587, 2587 (STARTTLS), 465, 2465 (TLS) | SES SMTP credentials |
| SendGrid | `smtp.sendgrid.net` | 25, 587, 2525 (TLS), 465 (SSL) | literal `apikey` / API key |
| Mailtrap | `live.smtp.mailtrap.io` | 587, 2525, 465 | `api` / API token |

Every provider accepts 587 or 2525. So the SMTP transport alone reaches
all of them from a VPS. On PaaS hosts that block outbound SMTP (Railway
below Pro, Render free, Fly by default; see `docs/deployment-options.md`
§4), a preset is the *only* way that works without a plan upgrade. That
is the real argument for presets at all.

## 3. Provider notes

### 3.1 Brevo (FR)

The largest EU-headquartered provider here, and the one with the best
*permanent* free tier (300/day ≈ 9,000/month). Brevo's own help centre
puts all hosting in the EU: OVH in France and Germany, plus Google Cloud
in Belgium. That page returns 403 to direct fetch; the claim comes from
its indexed text. The entity is Sendinblue SAS, Paris, per the privacy
policy. Caveats:
- Brevo is a marketing suite first. The volume on its plans is
  "campaigns & transactional" combined, and the pricing page only shows
  the Starter entry point (from 5,000 emails). Volume pricing
  (e.g. 20k at ~$32/mo) comes only from *secondary* sources.
- The free plan puts a Brevo logo on emails ("No Brevo logo" is a
  Starter feature). Whether that applies to API-sent transactional mail
  was not verified.
- New accounts must be approved before sending ("once we approve your
  account for sending, you can start sending up to 300 emails per day").
- The API needs `{email, name}` objects for sender, recipients and
  reply-to. That costs one helper that parses "Name \<addr\>". It is
  still well inside 15 lines.

### 3.2 Lettermint (NL)

The cleanest EU-sovereign option: its own AS213427 and IP ranges,
"no Amazon, Google, Microsoft or other US cloud providers involved", and
"nothing processed or transferred outside the EU". Footer: "© 2026
Lettermint® B.V. … Built in the Netherlands. Hosted in Europe."
Pricing is among the lowest listed (€10 for 10k, €40 for 50k on
Starter). It has spend limits that pause sending instead of billing
overage, which fits hobby deployments. Its API is a near-clone of
Resend's (`from`, `to[]`, `subject`, `text`, `html`, `reply_to[]`,
token header). So a Lettermint preset and a Resend preset are the same
code with two strings changed. It also has an `Idempotency-Key` header
and per-message TLS enforcement. Weakness: it is young and small. Its
npm SDK had ~54k downloads in the last month, versus ~39.5M for Resend.

### 3.3 Scaleway Transactional Email (FR)

By far the cheapest EU option. Pay-as-you-go at €0.25 per 1,000 after
300 free a month comes to about €12 for 50k, with no subscription. Built
on a French hyperscaler, `fr-par` only. It is billed per *recipient*,
not per message. Three things make it the most awkward EU preset:
- the API is still `v1alpha1`
- every request needs a `project_id` in the body
- there is no `reply_to` field; it goes in `additional_headers`
  (confirmed against `CreateEmailRequest` in Scaleway's Go SDK)

The free tier (300/month) is too small to matter. The price is
compelling at volume; the API ergonomics are not.

### 3.4 Mailjet (FR, owned by Sinch)

EU-hosted by default (GCP Frankfurt and Saint-Ghislain), with a decent
free tier (6,000/month, max 200/day) that carries a Mailjet logo. Its
v3.1 API fits a preset, but it needs a key *pair* (Basic auth) and a
`Messages:[…]` wrapper. The only published paid tier is $19 for 15k.
Its sister company Mailgun (same owner, Sinch) is the more
developer-oriented product of the two.

### 3.5 Sweego (FR)

A French company (MINDBAZ), hosted entirely in France (OVH, Scaleway,
Alter Way per its sub-processor list, updated 2026-07-15), with a 100/day
free tier. The pricing page shows "Individual — €10/month — 20 K or
50 K", and it is unclear whether both volumes cost €10. Treat the 50k
price as unverified. Its API has provider-specific quirks (`channel`,
`provider`, hyphenated `message-txt` / `message-html`; Reply-To only via a
`headers` map, as used by the Symfony Mailer bridge), and its SMTP host
is not documented publicly. Credible, but small and less documented.

### 3.6 MailPace (UK)

A UK company "hosted in the European Union", aimed at transactional
mail only. $10 for 10k, a free plan only on request (100/month), and a
Postmark-like API. The UK is outside the EU but has a GDPR adequacy
decision. Too small a user base to justify a built-in preset; SMTP
covers it.

### 3.7 Mailgun (US, Sinch; EU region)

A real EU region (`api.eu.mailgun.net`, `smtp.eu.mailgun.org`). Message
data, logs, suppressions and IPs "never leave the region". Account data,
billing and API keys are replicated globally. It is chosen per domain,
not by plan. The free plan is 100/day. The HTTPS API is
`multipart/form-data` with the domain in the URL path, which does not
fit the JSON-preset pattern. Leave it to SMTP. Mailgun does have a raw
MIME endpoint, which matters if `Monk::Mail` ever grows a MIME-over-HTTPS
path (see §5.3).

### 3.8 Resend (US)

The default choice of today's developer tooling, and the simplest API
here: Bearer token, and field names identical to Monk's message hash.
Free tier is 3,000/month (100/day). Pro is $20 for 50k, the cheapest
rate at 50k among the non-hyperscalers apart from Bird. **Not EU data
resident**: you can pick `eu-west-1` as a *sending* region, but "all
account data, including email metadata, logs, and API records, is
stored in the United States regardless of the sending region". The DPA
names the US as the primary processing location.

### 3.9 Postmark (US)

The deliverability reference for magic links. It keeps "parallel but
separate sending infrastructures" for transactional and broadcast mail,
which "never intersect … including IP ranges". It is not EU resident,
with no plans to be (data at Deft near Chicago and on AWS, EU transfers
under SCCs). The free tier is 100/month forever, meant for testing.
Basic is $15 for 10k. The API is trivial (a PascalCase rename). A strong
*worldwide* candidate; see the recommendation for why it is optional.

### 3.10 Amazon SES (US; EU regions)

Cheapest at scale ($0.10/1k à-la-carte; newer bundled plans from
$0.16/1k), with regional processing in six EU regions. The free-tier
model has changed: new accounts now get **up to $200 of general AWS
credits for 6 months**, not the old 3,000 messages/month.
`docs/deployment-options.md` §4 still quotes the old figure. The HTTPS
API needs **SigV4 request signing**, which rules out a zero-dependency
15-line preset. SES SMTP (`email-smtp.eu-west-1.amazonaws.com:587`) is
the right path, through the SMTP transport. New accounts start in a
sandbox (200 messages/24h, verified recipients only).

### 3.11 SendGrid (US, Twilio)

**Free plan retired.** New accounts since 2025-03-25 get a 60-day trial
(100/day), and the old free plan was retired from 2025-05-27. The
cheapest plan is Essentials, from $19.95 for 50k. EU data residency
requires **Pro or higher with a dedicated EU IP**, an EU subuser and the
`api.eu.sendgrid.com` endpoint. It has the most nested JSON of any
provider (`personalizations`, `content[]`). SMTP only.

### 3.12 Others checked

- **SMTP2GO** (NZ): 1,000/month free. It has an EU data centre in
  Amsterdam, and EU signups are "automatically … handled by our
  Amsterdam data centre". There is an `eu-api` host and a raw-MIME send
  endpoint. A good SMTP target, and a candidate if a MIME-over-HTTPS
  preset is ever built.
- **MailerSend** (US entity, EU hosting): the privacy policy names
  MailerSend, Inc., New York. Its GDPR page says services are hosted in
  Belgium (Google Cloud EMEA). Free is 500/month. The Starter price at
  50k could not be read from the pricing page (it renders client-side).
  The API is clean (Brevo-shaped, snake_case).
- **Mailtrap** (US): generous free tier (4,000/month). Its docs say
  "USA hosting" with EU storage planned for 2026, and there is no EU
  endpoint yet.
- **Bird / SparkPost**: `sparkpost.com/pricing` redirects to Bird.
  1,000/month free, then $0.30/1k from 50k. HQ and EU region were not
  verified.
- **Elastic Email**: 3,000/month free and $19 for 50k, as listed. HQ and
  EU hosting were not verified.
- **Infomaniak (CH)**: its public API covers mailboxes and newsletter
  campaigns. No transactional send API or relay product was found. Not
  a candidate.
- **IONOS, Loops, Plunk**: not investigated further. IONOS sells mailbox
  hosting, not a transactional API. Loops and Plunk are product-email /
  marketing tools, outside the scope of a framework mailer.

## 4. Popularity signal

The only credible, reproducible numbers found are SDK download counts
from the package registries. They measure *developer adoption of the
official SDK*, not sending volume or market share. They are skewed by
CI installs, by transitive dependencies, and (for AWS) by meta-gems
that pull in every service.

| Provider | npm SDK, last month (2026-08-26 → 09-24) | RubyGems SDK, all-time |
|---|---|---|
| Resend | `resend` 39.5M | `resend` 1.18M |
| SendGrid | `@sendgrid/mail` 16.7M | `sendgrid-ruby` 62.1M (last release 2023) |
| Amazon SES | `@aws-sdk/client-sesv2` 14.0M, `client-ses` 13.6M | `aws-sdk-ses` 131.5M, `aws-sdk-sesv2` 67.3M (inflated by `aws-sdk`) |
| Mailgun | `mailgun.js` 4.0M | `mailgun-ruby` 19.2M |
| Postmark | `postmark` 3.9M | `postmark` 21.6M, `postmark-rails` 12.4M |
| Brevo | `@getbrevo/brevo` 0.93M | `brevo` 0.27M, `sib-api-v3-sdk` 2.39M (old name) |
| Mailjet | `node-mailjet` 0.61M | `mailjet` 3.75M |
| MailerSend | `mailersend` 0.41M | `mailersend-ruby` 0.10M |
| Mailtrap | `mailtrap` 0.19M | `mailtrap` 0.46M |
| Lettermint | `lettermint` 54k | — |

Read against that caveat: Resend now leads new-project adoption by a
wide margin. SendGrid and SES dominate the installed base. Brevo is the
only EU provider with a sizeable developer footprint.

## 5. Recommendation

### 5.1 Ship three presets

1. **`brevo://API_KEY`: the EU default.** EU company, EU-hosted by
   default on every plan, the largest free tier in the list that never
   expires (300/day), and the widest adoption of any EU provider. Its
   object-shaped addresses cost one helper, not a design problem.
2. **`lettermint://TOKEN`: the EU-sovereign, transactional-only
   option.** It runs on its own EU infrastructure with no US
   hyperscaler, which is the strongest residency story here. It is
   cheaper than Postmark and Mailgun at 10k–50k, and dedicated to
   transactional mail. Its API has the same shape as Resend's, so the
   preset costs almost nothing once the Resend preset exists.
3. **`resend://KEY`: the worldwide default.** It is what most people
   reaching for a new framework already have an account with. It has
   the simplest possible mapping, a usable free tier (3,000/month) and
   $0.40/1k at 50k. Say plainly in the docs that it is **not** EU data
   resident.

This gives two EU presets out of three, with a single JSON shape shared
by two of them. It also covers the "I already have a Resend key" path,
which is where most new apps start.

**If only two:** Brevo + Resend (EU reach + worldwide popularity).
**Swap candidates:**
- Postmark instead of Resend, if magic-link deliverability outranks
  popularity and free-tier size. Its separated transactional
  infrastructure is the best-documented guarantee here.
- Scaleway instead of Lettermint, if lowest EU cost at volume is the
  goal (≈ €12 for 50k), accepting a `v1alpha1` API and a
  `PROJECT_ID:KEY` URL.

### 5.2 Leave to the SMTP transport

| Provider | Why not a preset |
|---|---|
| Amazon SES | SigV4 signing: not zero-dep, not 15 lines. SMTP in an EU region is fine |
| Mailgun | multipart form body + domain in path; SMTP has an EU host |
| SendGrid | no free tier; EU residency is Pro-only; heaviest JSON |
| Postmark (unless swapped in) | not EU; tiny free tier; SMTP works (stream via header) |
| Mailjet, SMTP2GO, MailerSend, Mailtrap, MailPace, Sweego, Scaleway | viable APIs, but smaller reach or quirkier shapes; SMTP covers them on any host that allows 587/2525 |

### 5.3 Design notes that fell out of the research

- **URL schemes have precedent.** Symfony Mailer uses DSNs such as
  `sweego+api://KEY@default` and `sweego+smtp://USER:PASS@HOST:PORT`.
  A `MAIL_URL` of `scheme://SECRET` for presets and
  `smtp://user:pass@host:587` for the transport follows the same
  convention, and extends to multi-part credentials
  (`scaleway://PROJECT:KEY@fr-par`, `mailjet://KEY:SECRET@`) if those
  are ever added.
- **Region belongs in the URL host for regional providers.** Mailgun,
  SendGrid, SMTP2GO and SES all use a separate EU hostname. The EU-native
  providers (Brevo, Lettermint, Scaleway) do not need one, which is one
  more reason to prefer them as presets.
- **A MIME-over-HTTPS preset is a possible later path.** Mailgun
  (`messages.mime`), SES (`Content.Raw`) and SMTP2GO (MIME endpoint)
  accept a pre-built MIME message. If the SMTP transport's MIME builder
  is exposed, one generic "post this MIME blob" preset could reach them
  over HTTPS. SES still needs SigV4.
- **Magic links are the use case, so deliverability beats price.**
  Whatever the preset, the docs should say: verify the sending domain
  (SPF, DKIM, DMARC). Use a transactional-only stream where the
  provider separates them (Postmark message streams, Lettermint routes).
  Set a tight `Net::HTTP` open/read timeout, because the send blocks a
  worker Ractor (P4).

## 6. What could not be verified

1. **Brevo** volume pricing beyond the Starter entry point, whether the
   free-plan logo applies to API transactional mail, and its storage
   page (403). The EU-hosting claim is from Brevo's help centre, read via
   its indexed text.
2. **Sweego** 50k price on the Individual plan, its SMTP host and ports,
   and whether its API has a first-class reply-to field.
3. **Mailjet** v3.1 `ReplyTo` field shape (reference page renders
   client-side).
4. **MailerSend** Starter price at 50k (pricing renders client-side).
5. **Bird/SparkPost** and **Elastic Email**: HQ and EU region
   availability.
6. **Mailgun** free-plan domain limit (help-centre page returns 403;
   taken from search-indexed text).
7. **Mailtrap** $20 for 50k is as read from the pricing page, and looks
   low next to $15 for 10k. Re-check before quoting it.

## Sources

Checked 2026-09-26.

**Brevo**
- [Pricing](https://www.brevo.com/pricing/): Starter from $9/€7, 5,000 emails, "No Brevo logo", free 300/day after approval, volume = campaigns + transactional
- [Send a transactional email: API reference](https://developers.brevo.com/reference/sendtransacemail)
- [SMTP relay](https://developers.brevo.com/docs/smtp-integration)
- [Privacy policy](https://www.brevo.com/legal/privacypolicy/): Sendinblue SAS, Paris
- [Data storage location](https://help.brevo.com/hc/en-us/articles/360001005510-Data-storage-location): 403 on direct fetch; content via search index
- [Brevo pricing 2026 (secondary)](https://www.sendx.io/blog/brevo-pricing-plans-costs-alternatives-2026): 20k at $32/mo

**Mailjet**
- [Pricing](https://www.mailjet.com/pricing/)
- [Send API v3.1 guide](https://dev.mailjet.com/email/guides/send-api-v31/)
- [Security & privacy](https://www.mailjet.com/legal/security-privacy/): GCP Frankfurt and Saint-Ghislain
- [SMTP configuration](https://dev.mailjet.com/docs/smtp-relay/configuration)

**Scaleway**
- [Managed services pricing: TEM](https://www.scaleway.com/en/pricing/managed-services/)
- [TEM product page](https://www.scaleway.com/en/transactional-email-tem/)
- [TEM API reference](https://www.scaleway.com/en/developers/api/transactional-email/)
- [`CreateEmailRequest` in scaleway-sdk-go](https://github.com/scaleway/scaleway-sdk-go/blob/master/api/tem/v1alpha1/tem_sdk.go): no `reply_to` field
- [Setting up SMTP](https://www.scaleway.com/en/docs/transactional-email/reference-content/smtp-configuration/)

**Lettermint**
- [Pricing](https://lettermint.co/pricing)
- [Homepage footer](https://lettermint.co/): Lettermint B.V., Netherlands
- [European email](https://lettermint.co/european-email): own AS, no US cloud
- [Sending API](https://lettermint.co/docs/api-reference/sending/send)
- [Node SDK types](https://github.com/lettermint/lettermint-node/blob/main/src/types.ts): `to: string[]`, `reply_to?: string[]`
- [SMTP guide](https://lettermint.co/docs/guides/send-email-with-smtp)

**Sweego**
- [Pricing](https://www.sweego.io/pricing)
- [API integration guide](https://www.sweego.io/channel/email/integrate-sweegos-api-to-send-transactional-emails)
- [DPA](https://www.sweego.io/data-privacy-agreement-dpa): MINDBAZ
- [Sub-processors](https://www.sweego.io/list-of-subsequent-subcontractors)
- [SMTP service page](https://www.sweego.io/channel/email/smtp-service-simple-fast-and-hosted-in-europe)
- [Symfony Sweego transport](https://github.com/symfony/symfony/blob/7.3/src/Symfony/Component/Mailer/Bridge/Sweego/Transport/SweegoApiTransport.php) and [DSN README](https://github.com/symfony/symfony/blob/7.2/src/Symfony/Component/Mailer/Bridge/Sweego/README.md)

**MailPace**
- [Pricing](https://mailpace.com/pricing)
- [Send endpoint](https://docs.mailpace.com/reference/send/)
- [SMTP](https://docs.mailpace.com/integrations/smtp/)

**Mailgun**
- [Pricing](https://www.mailgun.com/pricing/)
- [Send message API](https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages/post-v3--domain-name--messages)
- [SMTP](https://documentation.mailgun.com/docs/mailgun/user-manual/sending-messages/send-smtp)
- [Regions](https://www.mailgun.com/about/regions/)
- [Free plan](https://help.mailgun.com/hc/en-us/articles/203068914-What-does-the-Free-plan-offer): 403 on direct fetch

**SMTP2GO**
- [Pricing](https://www.smtp2go.com/pricing/)
- [API endpoints](https://developers.smtp2go.com/docs/endpoints)
- [Send standard email](https://developers.smtp2go.com/reference/send-standard-email)
- [API index, incl. MIME send](https://developers.smtp2go.com/llms.txt)
- [SMTP relay](https://developers.smtp2go.com/docs/smtp-relay)
- [EU sending](https://www.smtp2go.com/blog/sending-emails-eu-youll-want-read/)
- [About](https://www.smtp2go.com/about/): Christchurch, NZ

**MailerSend**
- [Pricing](https://www.mailersend.com/pricing)
- [Email API](https://developers.mailersend.com/api/v1/email.html)
- [GDPR page](https://www.mailersend.com/legal/how-mailersend-stays-gdpr-compliant): Belgium, Google Cloud EMEA
- [Privacy policy](https://www.mailersend.com/legal/privacy-policy): MailerSend, Inc.
- [SMTP relay](https://www.mailersend.com/help/smtp-relay)

**Resend**
- [Pricing](https://resend.com/pricing)
- [Send email API](https://resend.com/docs/api-reference/emails/send-email)
- [Regions](https://resend.com/docs/dashboard/domains/regions): account data stored in the US
- [DPA](https://resend.com/legal/dpa): Plus Five Five, Inc., San Francisco
- [SMTP](https://resend.com/docs/send-with-smtp)

**Postmark**
- [Pricing](https://postmarkapp.com/pricing)
- [Send with API](https://postmarkapp.com/developer/user-guide/send-email-with-api)
- [Send with SMTP](https://postmarkapp.com/developer/user-guide/send-email-with-smtp)
- [EU privacy](https://postmarkapp.com/eu-privacy): no EU servers planned
- [Message streams](https://postmarkapp.com/message-streams)

**Amazon SES**
- [Pricing](https://aws.amazon.com/ses/pricing/): $200 credits, $0.10/1k à-la-carte
- [SendEmail v2](https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html)
- [SMTP connection](https://docs.aws.amazon.com/ses/latest/dg/smtp-connect.html)
- [Endpoints and quotas](https://docs.aws.amazon.com/general/latest/gr/ses.html)

**SendGrid**
- [Email API pricing](https://www.twilio.com/en-us/products/email-api/pricing)
- [Mail Send API](https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send)
- [Free plan changes](https://www.twilio.com/en-us/changelog/sendgrid-free-plan)
- [60-day trial](https://support.sendgrid.com/hc/en-us/articles/35270136965403-Twilio-SendGrid-Trial-Account-Plan)
- [EU data residency FAQ](https://www.twilio.com/docs/sendgrid/data-residency/faq)
- [SMTP](https://www.twilio.com/docs/sendgrid/for-developers/sending-email/integrating-with-the-smtp-api)

**Mailtrap**
- [Pricing](https://mailtrap.io/pricing/)
- [Transactional sending docs](https://docs.mailtrap.io/developers/email-sending/transactional)
- [Privacy](https://mailtrap.io/privacy/): Railsware Products Studio LLC
- [SMTP integration](https://docs.mailtrap.io/email-api-smtp/setup/smtp-integration)

**Others**
- [Bird email pricing](https://bird.com/pricing/email?sp=true): redirect target of sparkpost.com/pricing
- [Elastic Email pricing](https://elasticemail.com/email-api-pricing)
- [Infomaniak API](https://www.infomaniak.com/en/support/faq/2581/discover-the-infomaniak-api)

**Popularity**
- npm downloads API, e.g. [`resend`](https://api.npmjs.org/downloads/point/last-month/resend), period 2026-08-26 → 2026-09-24
- RubyGems API, e.g. [`resend`](https://rubygems.org/api/v1/gems/resend.json)
