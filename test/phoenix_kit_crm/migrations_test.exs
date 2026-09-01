defmodule PhoenixKitCRM.MigrationsTest do
  @moduledoc """
  Pins the module-owned migration chain (`migration_module/0` →
  `PhoenixKitCRM.Migrations`): V01 adopts all ten `phoenix_kit_crm_*`
  tables (shape-identical to core's live DDL — verified against
  `v135.ex`/`v138.ex`/`v148.ex`/`v151.ex`/`v152.ex` in core) and adds the
  one genuinely new object, `phoenix_kit_crm_companies.user_uuid` (+ its
  partial unique index).

  Split, same as the `PhoenixKit.Modules.Legal.Migrations` precedent:

    * pure unit tests (no DB) on `current_version/0`, the prefix guard,
      and the SQL-as-data (`up_statements/1`) — including the
      idempotency proof: `execute/1` requires a live migration runner
      process (confirmed empirically — calling `Migrations.up/1`
      directly outside `Ecto.Migrator` raises `"could not find
      migration runner process"`), so "does calling `up` twice not
      raise" is proven at the SQL level (every statement is guarded)
      rather than by a second bare call;
    * DB-backed integration tests asserting the NEW effects only — the
      ten tables are already adopted by `test_helper.exs` at boot (via
      `Ecto.Migrator.run/4` against `PhoenixKitCRM.Test.SchemaMigration`,
      the same wrapper `mix phoenix_kit.update` uses in production
      through a real migration runner), so these tests do not re-create
      them.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCRM.Migrations

  describe "current_version/0 and version_table/0" do
    test "current_version is 5" do
      assert Migrations.current_version() == 5
    end

    test "version_table is the contacts table (the marker carrier)" do
      assert Migrations.version_table() == "phoenix_kit_crm_contacts"
    end
  end

  describe "prefix guard" do
    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", "", "bad;drop"] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end

    test "accepts a plain schema-safe prefix" do
      assert is_list(Migrations.up_statements("public"))
    end
  end

  describe "the chain never destroys CRM data" do
    test "no up or down statement matches DROP or TRUNCATE" do
      all =
        Migrations.up_statements() ++
          Migrations.down_statements("public", 0) ++
          Migrations.down_statements("public", 1)

      for stmt <- all do
        refute stmt =~ ~r/\bDROP TABLE\b|\bTRUNCATE\b/i,
               """
               A chain statement can destroy CRM data:

               #{stmt}

               up/1 adopts existing tables and down/1 only unstamps the version
               marker — neither may drop a table.
               """
      end
    end

    test "down to 0 removes the marker; down to a version restamps it" do
      assert Migrations.down_statements("public", 0) ==
               ["COMMENT ON TABLE public.phoenix_kit_crm_contacts IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_crm_contacts IS 'crm_schema:1'"]

      assert Migrations.down_statements("public", 2) ==
               ["COMMENT ON TABLE public.phoenix_kit_crm_contacts IS 'crm_schema:2'"]
    end
  end

  describe "up/1 is idempotent by construction" do
    test "every statement is guarded (IF NOT EXISTS / DO-block / COMMENT)" do
      for stmt <- Migrations.up_statements() do
        guarded? =
          stmt =~ "IF NOT EXISTS" or
            String.starts_with?(String.trim(stmt), "DO $$") or
            String.starts_with?(String.trim(stmt), "COMMENT ON TABLE")

        assert guarded?,
               """
               statement is not idempotent against an already-adopted table:

               #{stmt}
               """
      end
    end

    test "the version marker is stamped last, after every DDL statement it certifies" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_crm_contacts IS 'crm_schema:5'"
    end

    test "the extension guard runs first, before any citext column is created" do
      assert List.first(Migrations.up_statements()) == "CREATE EXTENSION IF NOT EXISTS citext"
    end
  end

  describe "V01 creates core's exact object names (shape-identical adoption)" do
    test "all ten table names appear" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for table <- [
            "phoenix_kit_crm_role_settings",
            "phoenix_kit_crm_user_role_view",
            "phoenix_kit_crm_contacts",
            "phoenix_kit_crm_companies",
            "phoenix_kit_crm_company_memberships",
            "phoenix_kit_crm_interactions",
            "phoenix_kit_crm_interaction_parties",
            "phoenix_kit_crm_party_roles",
            "phoenix_kit_crm_lists",
            "phoenix_kit_crm_list_members"
          ] do
        assert statements =~ table, "V01 does not mention #{table}"
      end
    end

    test "the new company↔user link and its partial unique index are present" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      assert statements =~
               "ALTER TABLE public.phoenix_kit_crm_companies ADD COLUMN IF NOT EXISTS user_uuid UUID REFERENCES public.phoenix_kit_users(uuid) ON DELETE SET NULL"

      assert statements =~ "idx_crm_companies_user_uuid"
      assert statements =~ "WHERE user_uuid IS NOT NULL"
    end
  end
end

defmodule PhoenixKitCRM.MigrationsIntegrationTest do
  @moduledoc """
  DB-backed effects of V01. `test_helper.exs` already applied the chain at
  boot (through a real `Ecto.Migrator` runner, against
  `PhoenixKitCRM.Test.SchemaMigration`) — the ten tables were either
  already there (adoption, the common case today) or got created fresh.
  These tests assert the effects that are NEW to this chain, not table
  creation.
  """

  use PhoenixKitCRM.DataCase

  alias PhoenixKitCRM.Migrations
  alias PhoenixKitCRM.Test.SchemaMigration

  describe "companies.user_uuid (the new mirror link)" do
    test "the column exists, nullable, uuid" do
      %{rows: [[data_type, is_nullable]]} =
        Repo.query!("""
        SELECT data_type, is_nullable FROM information_schema.columns
        WHERE table_name = 'phoenix_kit_crm_companies' AND column_name = 'user_uuid'
        """)

      assert data_type == "uuid"
      assert is_nullable == "YES"
    end

    test "the FK targets phoenix_kit_users ON DELETE SET NULL" do
      %{rows: rows} =
        Repo.query!("""
        SELECT confdeltype, confrelid::regclass::text
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = 'phoenix_kit_crm_companies' AND c.contype = 'f'
        """)

      assert {"n", "phoenix_kit_users"} in Enum.map(rows, fn [type, target] -> {type, target} end),
             "expected an ON DELETE SET NULL (confdeltype='n') FK to phoenix_kit_users, got: #{inspect(rows)}"
    end

    test "the partial unique index exists" do
      %{rows: [[indexdef]]} =
        Repo.query!("""
        SELECT indexdef FROM pg_indexes
        WHERE tablename = 'phoenix_kit_crm_companies' AND indexname = 'idx_crm_companies_user_uuid'
        """)

      assert indexdef =~ "UNIQUE"
      assert indexdef =~ "user_uuid"
      assert indexdef =~ "WHERE"
    end
  end

  describe "migrated_version_runtime/1" do
    test "reads back 5 after the chain has applied" do
      assert Migrations.migrated_version_runtime(prefix: "public") == 5
    end

    test "an unsafe prefix reads as 0, not raised — the function guards its own boundary" do
      # migrated_version_runtime/1 wraps its whole body in `rescue _ -> 0`
      # (a runtime probe must not crash its caller), so the ArgumentError
      # `validated_prefix/1` raises for an unsafe prefix is caught here
      # rather than propagated — unlike up/1 and down/1, which run inside
      # a migration and are meant to halt it. This pins that boundary.
      assert Migrations.migrated_version_runtime(prefix: "bad;drop") == 0
    end
  end

  describe "idempotency against the live database" do
    # `execute/1` needs a live migration runner process, so `up/1` cannot
    # be invoked bare in a test (confirmed empirically: it raises "could
    # not find migration runner process"). Re-running it for real is done
    # the same way `mix phoenix_kit.update` would on a second invocation —
    # through `Ecto.Migrator`, which recognizes the version is already
    # applied and skips re-execution rather than raising.
    test "re-running the chain's version through the migrator is a safe no-op" do
      result =
        Ecto.Migrator.up(
          Repo,
          SchemaMigration.migrator_version(),
          SchemaMigration,
          log: false
        )

      assert result in [:already_up, :ok]

      # And the effects are unchanged.
      assert Migrations.migrated_version_runtime(prefix: "public") == 5
    end
  end

  describe "V04 legacy normalisation" do
    test "normalises legacy client rows BEFORE adding the role CHECK" do
      statements = Migrations.up_statements()

      normalise_at =
        Enum.find_index(statements, &(&1 =~ "SET role = 'customer' WHERE role = 'client'"))

      check_at = Enum.find_index(statements, &(&1 =~ "phoenix_kit_crm_party_roles_role_check"))

      assert normalise_at, "V04 must normalise legacy 'client' rows"
      assert check_at, "V04 must add the role CHECK"

      # ADD CONSTRAINT validates existing rows: constrain before cleaning and
      # any install still holding a 0.2.x `client` row fails the migration.
      assert normalise_at < check_at
    end

    test "drops a legacy row whose party already holds customer, so the rename cannot collide" do
      statements = Migrations.up_statements()

      assert Enum.any?(statements, fn s ->
               s =~ "DELETE FROM" and s =~ "legacy.role = 'client'" and s =~ "'customer'"
             end)
    end

    test "adds the partial unique index that makes a dual-type active role impossible" do
      assert Enum.any?(Migrations.up_statements(), fn s ->
               s =~ "phoenix_kit_crm_party_roles_active_uniq" and s =~ "WHERE is_active"
             end)
    end
  end

  # From the 2026-08-21 external review. V04 rewrites live role data, so its
  # SQL is pinned by shape here — the suite has no pre-V04 fixture database to
  # run it against, and a statement-level assertion still catches the two ways
  # the original could destroy or abort.
  describe "V04 legacy normalisation — data-safety fixes" do
    test "the legacy DELETE never drops a live role for a merely dormant customer" do
      sql = Enum.join(Migrations.up_statements(), "\n")

      # The redundancy test must consider is_active. Without it, an ACTIVE
      # `client` is deleted because a long-revoked `customer` exists.
      assert sql =~ "current.is_active OR NOT legacy.is_active",
             "the client/customer DELETE must not ignore is_active"

      # And the mirror case: a dormant customer beside a live client has to go,
      # or the rename collides with the older unique index.
      assert sql =~ "dormant.role = 'customer'"
      assert sql =~ "NOT dormant.is_active"
    end

    test "active duplicates are deactivated before the partial unique index" do
      statements = Migrations.up_statements()

      dedupe = Enum.find_index(statements, &(&1 =~ "PARTITION BY roleable_uuid, role"))
      index = Enum.find_index(statements, &(&1 =~ "phoenix_kit_crm_party_roles_active_uniq"))

      assert dedupe, "V04 must deactivate cross-type active duplicates"
      assert index, "V04 must create the partial unique index"

      assert dedupe < index,
             "the dedupe has to run BEFORE the index, or CREATE UNIQUE INDEX aborts the migration"
    end

    test "the dedupe keeps the company side, matching the documented tiebreak" do
      sql = Enum.join(Migrations.up_statements(), "\n")
      assert sql =~ "(roleable_type = 'company') DESC"
    end
  end
end
