defmodule PhoenixKitCRM.Test.SchemaMigration do
  @moduledoc """
  Test-boot wrapper around the module-owned migration chain (the
  `phoenix_kit_document_creator` precedent): `test_helper.exs` runs this
  through `Ecto.Migrator`, keyed on `migrator_version/0`, so a chain bump
  re-applies automatically. `execute/1` inside `PhoenixKitCRM.Migrations`
  requires a live migration runner process — this wrapper is how the test
  suite provides one outside of `mix phoenix_kit.update`.
  """

  use Ecto.Migration

  alias PhoenixKitCRM.Migrations

  # `schema_migrations` on the shared library test DB (`migration_test_db`,
  # ~37 projects) is one physical table every sibling module's own
  # `Ecto.Migrator.run` call writes into. `Migrations.current_version/0` is
  # a small integer (1, 2, ...) private to THIS chain's own `crm_schema:N`
  # marker convention — reusing it as the Migrator's bookkeeping version
  # collides with unrelated chains (confirmed: version `1` was already
  # recorded by something else, so a naive `{1, __MODULE__}` entry was
  # silently treated as "already applied" and never actually ran). This
  # offset keeps the Migrator record in a band no other package's version
  # numbers land in.
  @spec migrator_version() :: pos_integer()
  def migrator_version, do: 979_797_970_000_000 + Migrations.current_version()

  def up, do: Migrations.up(prefix: "public")
  def down, do: Migrations.down(prefix: "public")
end
