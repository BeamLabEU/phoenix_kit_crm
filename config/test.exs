import Config

# Integration tests need a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_crm_test
config :phoenix_kit_crm, ecto_repos: [PhoenixKitCRM.Test.Repo]

config :phoenix_kit_crm, PhoenixKitCRM.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_crm_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :phoenix_kit, repo: PhoenixKitCRM.Test.Repo

# Test Endpoint for the LiveView suite. phoenix_kit_crm has no endpoint of its
# own in production — the host app provides one — so this exists only for
# Phoenix.LiveViewTest.
config :phoenix_kit_crm, PhoenixKitCRM.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "crm-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitCRM.Test.Layouts]],
  pubsub_server: PhoenixKitCRM.Test.PubSub

config :phoenix, :json_library, Jason

config :logger, level: :warning
