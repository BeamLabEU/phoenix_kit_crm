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

config :logger, level: :warning
