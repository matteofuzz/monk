require_relative "../push/errors"
require_relative "../push/base64_url"
require_relative "../push/keys"

# Web push (Monk::Push): notifications to the devices where a signed-in
# person turned them on, sent from jobs (docs/plan-pwa-push.md, part B).
Monk::Generator.define(:push) do
  summary "Web push notifications, from jobs"
  installed_if "config/push.rb"
  depends_on :pwa, :jobs, :auth

  copy "config/push.rb", role: :wiring
  copy "app/routes/push.rb", role: :example
  copy "app/views/push/_settings.erb", role: :view
  copy "test/push_test.rb", role: :test
  migration "create_push_tables"

  # A fresh VAPID pair for .env and another for .env.test, every time the
  # module is added: the public key's line makes it, the private key's
  # line (written right after) takes the same pair. A file that already
  # has one key and not the other gets a mismatch, which boot reports.
  pending = {}
  %i[development test].each do |file|
    env file, {
      "VAPID_PUBLIC_KEY" => ->(app) { (pending[[file, app]] = Monk::Push::Keys.generate)[:public_key] },
      "VAPID_PRIVATE_KEY" => ->(app) { (pending.delete([file, app]) || Monk::Push::Keys.generate)[:private_key] },
      "VAPID_CONTACT" => ->(app) { "mailto:push@#{app}.example" },
    }
  end
  env :example, { "VAPID_PUBLIC_KEY" => "from-monk-push-keys", "VAPID_PRIVATE_KEY" => "from-monk-push-keys",
                  "VAPID_CONTACT" => "mailto:ops@your-domain.example", }, commented: true

  setup_section "push/setup.md"
  agents_section "push/agents.md"
  set_before_production "VAPID_PUBLIC_KEY", "`monk push keys`, a pair of its own; changing it ends every subscription"
  set_before_production "VAPID_PRIVATE_KEY", "the same `monk push keys` pair"
  set_before_production "VAPID_CONTACT", "mailto: or https: where push services can reach you", placeholder: true
  example "push-subscribe", todo: "uncomment: push.js stores each browser's subscription through it"
  example "push-notify", todo: "uncomment to try it, then call Monk::Push.notify where your app has news"
  closing "Then render the switch in a page: <%= render \"push/_settings\", layout: false %> " \
          '(app/routes/push.rb, block "push-subscribe", must be on).'
end
