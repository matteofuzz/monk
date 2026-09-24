# First publish of `monkrb` to RubyGems

Auth approach: Option 1 (`gem signin` + `gem push`) with a scoped API key —
see [`release_gem.md`](release_gem.md) for why this was chosen over Trusted
Publishing.

The gem doesn't exist under the account yet, so RubyGems can't offer it in
an API key's "gems this key can access" list on the first push. That means
the very first push has to use a temporarily broader key, immediately
replaced by a properly scoped one. Two phases:

## 1. Make sure the account has MFA enabled

`monkrb.gemspec` sets `"rubygems_mfa_required" => "true"`, so RubyGems will
refuse pushes without it once the gem exists there.

- Sign in at rubygems.org with matteo.folin@gmail.com (create the account
  first if needed).
- **Edit Profile → Multifactor Authentication** → enable it (authenticator
  app).

## 2. Mint a temporary key for the first push

On the rubygems.org website (not the CLI):

- **Edit Profile → API Keys → New API Key**
- **Name**: `monkrb-first-push` (recognizable, so it's easy to find and
  delete afterward)
- **Scopes**: check only **"Push rubygem"** — nothing else
- **Gems this key can access**: leave as "all gems" — `monkrb` isn't
  selectable yet since it hasn't been published
- **MFA**: check "Require MFA for this key" if offered
- **Expiration**: set a short one if offered (a day or two) — this key is
  meant to be used exactly once
- Create it and copy the key (shown once).

## 3. Store the key, build, and push

`gem signin` is interactive-only (email/password or `--otp`) — it has no
`--key` flag. To use an API key directly, write it into
`~/.gem/credentials` yourself:

```
ruby -ryaml -e '
creds_path = File.expand_path("~/.gem/credentials")
creds = File.exist?(creds_path) ? (YAML.load_file(creds_path) || {}) : {}
creds[:rubygems_api_key] = "<the-temporary-key>"
File.write(creds_path, creds.to_yaml)
File.chmod(0600, creds_path)
'
gem build monkrb.gemspec
gem push monkrb-0.15.0.gem
```

If the key requires MFA, `gem push` prompts for an OTP from the
authenticator app.

Verify the release landed: `https://rubygems.org/gems/monkrb`.

## 4. Immediately swap the temporary key for a scoped one

Now that `monkrb` exists under the account:

- **Edit Profile → API Keys** → **delete** `monkrb-first-push` right away —
  its job is done and it's broader than it needs to be kept around.
- Create a new key: same **"Push rubygem"**-only scope, but this time
  restrict **"Gems this key can access"** to `monkrb` specifically (it's
  now selectable).
- Replace the stored credential with this one:
  ```
  ruby -ryaml -e '
  creds_path = File.expand_path("~/.gem/credentials")
  creds = File.exist?(creds_path) ? (YAML.load_file(creds_path) || {}) : {}
  creds[:rubygems_api_key] = "<the-new-scoped-key>"
  File.write(creds_path, creds.to_yaml)
  File.chmod(0600, creds_path)
  '
  ```
  This overwrites the `:rubygems_api_key` entry in `~/.gem/credentials`
  without touching any other keys stored there.

From then on, every future `gem push monkrb-<version>.gem` uses the
properly scoped key, and the window where a broader key existed is
already closed.
