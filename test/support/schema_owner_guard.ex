defmodule PhoenixKitCRM.Test.SchemaOwnerGuard do
  @moduledoc """
  I067: `config/test.exs` lets `PGDATABASE` override this repo's isolated
  test DB name. Ecto.Migrator's `schema_migrations` bookkeeping table is
  keyed only by version number, with no package namespace — pointing
  `PGDATABASE` at a database another package's migrator already owns makes
  same-numbered migrations from this package silently get treated as
  "already applied" and never run (confirmed live via `Ecto.Migrator.run/4`
  in the I067 recon). This stamps a `COMMENT ON TABLE schema_migrations`
  marker naming the owning package, and refuses to proceed if a stamped
  marker names someone else.

  Only engages when `PGDATABASE` is explicitly set — the default, isolated
  per-repo DB is unaffected either way.
  """

  @package "phoenix_kit_crm"

  defmodule OwnerMismatch do
    defexception [:message]
  end

  @doc "Raises `OwnerMismatch` if the DB's schema_migrations marker names a different package."
  @spec check!((String.t() -> %{rows: list()})) :: :ok
  def check!(query_fn) do
    if System.get_env("PGDATABASE") do
      case owner(query_fn) do
        nil ->
          :ok

        owner when owner == @package ->
          :ok

        other ->
          raise OwnerMismatch,
            message: """
            PGDATABASE points at a database whose migration history belongs to \
            #{other}, not #{@package} — this would silently corrupt or skip \
            migrations. Use an isolated test DB, or a fresh one, instead.\
            """
      end
    else
      :ok
    end
  end

  @doc "Stamps this package as schema_migrations' owner. No-op unless PGDATABASE is set."
  @spec stamp!((String.t() -> %{rows: list()})) :: :ok
  def stamp!(query_fn) do
    if System.get_env("PGDATABASE") do
      query_fn.("COMMENT ON TABLE schema_migrations IS '#{@package}'")
    end

    :ok
  end

  defp owner(query_fn) do
    %{rows: [[table_exists?]]} =
      query_fn.(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'schema_migrations')"
      )

    if table_exists? do
      %{rows: [[comment]]} =
        query_fn.("SELECT obj_description('schema_migrations'::regclass, 'pg_class')")

      comment
    else
      nil
    end
  end
end
