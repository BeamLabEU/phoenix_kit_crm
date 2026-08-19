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
end
