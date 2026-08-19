defmodule PhoenixKitCRM.SchemaOwnerGuardWiringTest do
  @moduledoc """
  I067, closing the gap Pi's review found in the mechanism's own verification:
  every existing `SchemaOwnerGuardTest` calls `check!/1`/`stamp!/1` DIRECTLY —
  none of them go through `test_helper.exs`'s actual boot sequence, the only
  place the guard is really wired in. Deleting the wiring calls from
  `test_helper.exs` entirely leaves all five of those tests green; they prove
  the module works, not that anything still calls it.

  This test runs `test_helper.exs` for real, as a fresh `mix test` subprocess
  against a scratch database, then checks the marker from OUTSIDE that process
  — closing both gaps a unit test of the module alone cannot: "the marker
  isn't stamped" and "the wiring that stamps it was cut" produce the exact
  same observable symptom here, and both fail this test.
  """

  use ExUnit.Case, async: false

  @scratch_db "i067_wiring_scratch"

  # Cloned from the repo's own already-migrated isolated test DB via
  # `CREATE DATABASE ... TEMPLATE`, rather than created empty. An empty
  # scratch DB forces test_helper.exs's boot to run core's full V135->V169
  # chain from scratch before it ever reaches SchemaOwnerGuard.stamp!/1 —
  # slow, and observed to fail partway through for a reason unrelated to
  # this guard ("No repository configured for PhoenixKit" mid-chain, a
  # pre-existing gap in the cold-boot path, not touched here). Cloning an
  # already-migrated DB means the boot's migration step is a fast no-op and
  # this test's signal is about the guard's wiring, not about that chain.
  @template_db "phoenix_kit_crm_test"

  setup do
    admin_opts = [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      database: "postgres"
    ]

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{@scratch_db}", [])

    Postgrex.query!(
      admin,
      "CREATE DATABASE #{@scratch_db} TEMPLATE #{@template_db}",
      []
    )

    on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(admin_opts)
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{@scratch_db}", [])
    end)

    %{admin_opts: admin_opts}
  end

  test "a real boot through test_helper.exs stamps the owner marker", %{admin_opts: admin_opts} do
    env = [
      {"PGDATABASE", @scratch_db},
      {"PGHOST", to_string(admin_opts[:hostname])},
      {"PGPORT", to_string(admin_opts[:port])},
      {"PGUSER", admin_opts[:username]},
      {"PGPASSWORD", admin_opts[:password]}
    ]

    # A single fast, unrelated test file. test_helper.exs's boot code (which
    # calls SchemaOwnerGuard.check!/1 then, after migrating, stamp!/1) runs
    # unconditionally as part of loading the file — which target test runs is
    # irrelevant, only that `mix test` boots the suite at all.
    {output, exit_code} =
      System.cmd("mix", ["test", "test/phoenix_kit_crm/search_test.exs"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    assert exit_code == 0, "real boot against a fresh scratch DB should succeed:\n#{output}"

    {:ok, checker} = Postgrex.start_link(Keyword.put(admin_opts, :database, @scratch_db))

    marker =
      case Postgrex.query!(
             checker,
             "SELECT obj_description('schema_migrations'::regclass, 'pg_class')",
             []
           ) do
        %{rows: [[value]]} -> value
      end

    assert marker == "phoenix_kit_crm",
           "wiring did not stamp the owner marker (got #{inspect(marker)}) — either " <>
             "SchemaOwnerGuard.stamp!/1 was never called, or the wiring calling it was cut; " <>
             "a unit test of the module alone cannot distinguish either from a passing run"
  end

  # Kimi's review of round 1 found this test proved only the stamping half of
  # the wiring. Pi's two mutations (delete both calls; neutralize stamp!/1)
  # both remove the stamp — a mutation that deletes ONLY the check!/1 call
  # passed both of them unnoticed: the marker still gets set, this test still
  # goes green, and the guard no longer refuses on someone else's marker —
  # exactly the half check!/1 exists for. Stamping is bookkeeping; refusing is
  # the protection. Same real-subprocess-plus-outside-assertion shape as the
  # first test, mirrored onto the other half of the wiring.
  @foreign_db "i067_wiring_scratch_foreign"

  # Templated from `phoenix_kit_crm_test` (like the stamping test), for a
  # reason that took a run to discover: an EMPTY scratch DB forces
  # `PhoenixKit.Migration.ensure_current/2` to run core's full V135->V169
  # chain from scratch on every boot, including a boot this test WANTS to
  # crash before reaching — and that cold-boot chain has its own pre-existing
  # flakiness (observed to fail partway through on "No repository configured
  # for PhoenixKit", unrelated to this guard), which confounded this exact
  # test with a false red for the wrong reason. Core's own migration
  # bookkeeping lives in a separate table this guard never touches (a fully
  # empty `phoenix_kit_dev` was found, separately, to carry zero rows there
  # under version numbers below 1000 even after 170 core-created tables
  # existed — core does not use the generic `schema_migrations` table at
  # all), so templating from an already-core-migrated DB sidesteps the crash
  # entirely without touching anything the guard itself is being judged on.
  #
  # What DOES need to be absent, and isn't in the raw template, is the
  # uuid-ossp extension — the step `test_helper.exs` runs immediately after
  # check!/1 was originally positioned. Dropped here so the extension's
  # presence afterward is a direct, order-sensitive signal: `CREATE EXTENSION
  # IF NOT EXISTS` is idempotent, so if it were already present (as it is in
  # the raw template) a late check! running after it would look identical to
  # check! never having let it run at all. Kimi's round-2 review is exactly
  # this: a migrated template makes the DB-untouched assertion blind to
  # check!/1 running too LATE, because the steps after it are idempotent.
  test "a real boot through test_helper.exs refuses someone else's marker, before touching anything" do
    admin_opts = [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: System.get_env("PGUSER", "postgres"),
      password: System.get_env("PGPASSWORD", "postgres"),
      database: "postgres"
    ]

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{@foreign_db}", [])
    Postgrex.query!(admin, "CREATE DATABASE #{@foreign_db} TEMPLATE #{@template_db}", [])

    {:ok, seeder} = Postgrex.start_link(Keyword.put(admin_opts, :database, @foreign_db))
    Postgrex.query!(seeder, "DROP EXTENSION IF EXISTS \"uuid-ossp\"", [])

    Postgrex.query!(
      seeder,
      "COMMENT ON TABLE schema_migrations IS 'phoenix_kit_document_creator'",
      []
    )

    before_state = snapshot(seeder)

    # Sanity on the snapshot itself, not on the guard: if the extension is
    # somehow still present, the "untouched" comparison below would be
    # trivially satisfied by coincidence rather than by check!/1 actually
    # stopping in time — exactly the blindness this test exists to remove.
    assert before_state.extensions == []

    on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(admin_opts)
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{@foreign_db}", [])
    end)

    env = [
      {"PGDATABASE", @foreign_db},
      {"PGHOST", to_string(admin_opts[:hostname])},
      {"PGPORT", to_string(admin_opts[:port])},
      {"PGUSER", admin_opts[:username]},
      {"PGPASSWORD", admin_opts[:password]}
    ]

    {output, exit_code} =
      System.cmd("mix", ["test", "test/phoenix_kit_crm/search_test.exs"],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    refute exit_code == 0,
           "boot against a foreign-marked DB should refuse, not succeed:\n#{output}"

    assert output =~ "phoenix_kit_document_creator",
           "refusal happened but without naming the actual owner — not the legible message " <>
             "the guard promises:\n#{output}"

    assert output =~ "OwnerMismatch",
           "process failed, but not with the guard's own exception — some other crash " <>
             "reached the same exit code, which this assertion exists to rule out:\n#{output}"

    {:ok, checker} = Postgrex.start_link(Keyword.put(admin_opts, :database, @foreign_db))
    after_state = snapshot(checker)

    assert after_state.marker == "phoenix_kit_document_creator",
           "the refusal should leave the DB exactly as it found it, but the marker is now " <>
             "#{inspect(after_state.marker)} — something ran after check!/1 raised"

    assert after_state.extensions == [],
           "uuid-ossp exists now, which test_helper.exs only creates AFTER check!/1 — " <>
             "check!/1 must have run too late, letting a real step through before refusing " <>
             "(the fault Kimi's round-2 review named: an order violation the earlier " <>
             "template-based version of this test could not have caught, since re-creating " <>
             "an already-present extension is a silent no-op)"

    assert after_state.tables == before_state.tables,
           "the table set changed (before: #{inspect(before_state.tables)}, " <>
             "after: #{inspect(after_state.tables)}) — something created or dropped a table " <>
             "after check!/1 should have stopped the boot outright"
  end

  defp snapshot(conn) do
    %{rows: table_rows} =
      Postgrex.query!(
        conn,
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = 'public' ORDER BY table_name",
        []
      )

    %{rows: extension_rows} =
      Postgrex.query!(conn, "SELECT extname FROM pg_extension WHERE extname = 'uuid-ossp'", [])

    %{rows: [[marker]]} =
      Postgrex.query!(
        conn,
        "SELECT obj_description('schema_migrations'::regclass, 'pg_class')",
        []
      )

    %{
      tables: Enum.map(table_rows, fn [name] -> name end),
      extensions: Enum.map(extension_rows, fn [name] -> name end),
      marker: marker
    }
  end
end
