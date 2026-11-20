# The app on one Linux host with Docker: compose.yaml, a Caddyfile, and
# the production settings, from the modules installed. Each module adds
# its own services and settings (compose_section, production_env_section),
# when deploy is added or after. Nothing in it names a host provider.
Monk::Generator.define(:deploy) do
  summary "Docker Compose stack for one host: Caddy, the app's processes, Postgres"
  installed_if "compose.yaml"

  copy "compose.yaml", "Caddyfile", role: :wiring, app_name: true
  copy ".env.production.example", from: "deploy/env.production", role: :wiring
  copy "bin/deploy_env", role: :wiring, executable: true
  ignore "!/.env.production.example"

  setup_section "deploy/setup.md"
  agents_section "deploy/agents.md"
  next_step "set PUBLIC_URL and SITE_ADDRESS in .env.production.example, then on the host bin/deploy_env"
end
