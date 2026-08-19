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

  # Round 6 (Kimi): fixed, literal DB names are the one remaining real risk
  # once the comparison itself is sound — two concurrent `mix test` runs
  # against the same shared Postgres instance (the exact "migration_test_db"
  # scenario I067 exists for in the first place) would `DROP DATABASE IF
  # EXISTS`/`CREATE DATABASE` on top of each other under a fixed name.
  # Suffixed per-setup with real randomness (not a PID or node name — either
  # could coincidentally repeat across two different hosts hitting the same
  # shared instance, which random bytes practically can't).
  defp unique_suffix, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  @scratch_db_prefix "i067_wiring_scratch"

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

    scratch_db = "#{@scratch_db_prefix}_#{unique_suffix()}"

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{scratch_db}", [])

    Postgrex.query!(
      admin,
      "CREATE DATABASE #{scratch_db} TEMPLATE #{@template_db}",
      []
    )

    # Round 5: `#{@template_db}` itself carries the "phoenix_kit_crm" marker
    # (stamped by some earlier, legitimate boot against it directly) — found
    # by mutation-testing this exact test, where neutralizing stamp!/1 still
    # left it green. A clone inherits the marker regardless of whether THIS
    # boot's stamp!/1 call runs, the same no-op-looks-like-a-write blindness
    # round 5 fixed for the extension and function in the refusal test
    # below, applied here to the marker itself: cleared right after cloning
    # so its presence afterward is actually caused by this run's own boot.
    {:ok, cleaner} = Postgrex.start_link(Keyword.put(admin_opts, :database, scratch_db))
    Postgrex.query!(cleaner, "COMMENT ON TABLE schema_migrations IS NULL", [])

    on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(admin_opts)
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{scratch_db}", [])
    end)

    %{admin_opts: admin_opts, scratch_db: scratch_db}
  end

  test "a real boot through test_helper.exs stamps the owner marker", %{
    admin_opts: admin_opts,
    scratch_db: scratch_db
  } do
    env = [
      {"PGDATABASE", scratch_db},
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

    {:ok, checker} = Postgrex.start_link(Keyword.put(admin_opts, :database, scratch_db))

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
  @foreign_db_prefix "i067_wiring_scratch_foreign"

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

    foreign_db = "#{@foreign_db_prefix}_#{unique_suffix()}"

    {:ok, admin} = Postgrex.start_link(admin_opts)
    Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{foreign_db}", [])
    Postgrex.query!(admin, "CREATE DATABASE #{foreign_db} TEMPLATE #{@template_db}", [])

    {:ok, seeder} = Postgrex.start_link(Keyword.put(admin_opts, :database, foreign_db))
    Postgrex.query!(seeder, "DROP EXTENSION IF EXISTS \"uuid-ossp\"", [])

    # Round 5 (Kimi): the template (`phoenix_kit_crm_test`) already carries
    # `uuid_generate_v7/0` from its own earlier boot, same as it carries
    # uuid-ossp. `CREATE OR REPLACE FUNCTION` against an unmodified clone is
    # a genuine catalog no-op — a schema-only dump is byte-identical whether
    # the statement ran or not, so a mutation moving that creation ahead of
    # check!/1 would be invisible on this fixture no matter how the
    # before/after comparison works.
    #
    # Can't fix this the way the extension is fixed (drop it outright): this
    # function is the DEFAULT on the uuid primary key of ~170 tables in this
    # schema, so `DROP FUNCTION` refuses without CASCADE, and CASCADE would
    # strip the DEFAULT clause from every one of them — a much bigger,
    # unrelated fixture mutation (confirmed by trying it: `DROP FUNCTION IF
    # EXISTS uuid_generate_v7()` fails outright with exactly this dependency
    # list). Swapping the body instead keeps the signature — name, arg
    # types, return type — identical, so every column DEFAULT stays valid
    # throughout; only the function's own definition differs, which is all
    # that needs to be true for the real `CREATE OR REPLACE FUNCTION` in
    # test_helper.exs to be a genuine, dump-visible write instead of a
    # no-op.
    Postgrex.query!(
      seeder,
      "CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid AS $$ " <>
        "SELECT '00000000-0000-0000-0000-000000000000'::uuid; " <>
        "$$ LANGUAGE sql",
      []
    )

    Postgrex.query!(
      seeder,
      "COMMENT ON TABLE schema_migrations IS 'phoenix_kit_document_creator'",
      []
    )

    before_dump = schema_dump(foreign_db, admin_opts)
    before_versions = migration_versions(foreign_db, admin_opts)

    # Sanity on the fixture itself, not on the guard: if the extension is
    # somehow still present, or the function still carries its real body
    # instead of the placeholder just installed, the "untouched" comparison
    # below would be trivially satisfied by coincidence (a no-op re-run)
    # rather than by check!/1 actually stopping in time — exactly the
    # blindness this test exists to remove.
    refute before_dump =~ "uuid-ossp",
           "fixture still carries the uuid-ossp extension after dropping it"

    refute before_dump =~ "clock_timestamp",
           "fixture still carries the real uuid_generate_v7 body — the placeholder swap " <>
             "above didn't take, so its real (re-)creation below would be a no-op"

    on_exit(fn ->
      {:ok, admin} = Postgrex.start_link(admin_opts)
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{foreign_db}", [])
    end)

    env = [
      {"PGDATABASE", foreign_db},
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

    # Round 6 (Kimi): the primary harm I067 exists to prevent — a foreign
    # package's migration silently marked "applied" in someone else's
    # bookkeeping — is a DATA change to schema_migrations, and
    # `pg_dump --schema-only` never serializes table rows by design. A
    # migrator that runs before check!/1's refusal takes effect writes
    # exactly that row and the structural diff below would never see it.
    # Checked first, ahead of the structural diff, so a mutation that ONLY
    # touches this table's rows (a future migration whose sole effect is the
    # bookkeeping insert, not a structural change) is caught by this
    # assertion specifically, not incidentally by the one after it.
    after_versions = migration_versions(foreign_db, admin_opts)

    assert after_versions == before_versions,
           "the refusal should leave schema_migrations' rows untouched, but the applied-" <>
             "version list changed from #{inspect(before_versions)} to " <>
             "#{inspect(after_versions)} — the migrator recorded this migration as applied " <>
             "in someone else's bookkeeping before check!/1's refusal took effect, which is " <>
             "the exact harm I067 exists to prevent"

    after_dump = schema_dump(foreign_db, admin_opts)

    assert after_dump == before_dump, schema_diff_message(before_dump, after_dump)
  end

  # Round 6 (Kimi): `pg_dump --schema-only` is the right tool for catalog
  # structure and was never going to cover this — it explicitly excludes
  # table data by design, not by oversight. `schema_migrations` is the one
  # table in this whole test where DATA is the thing I067 actually protects
  # (a version number recorded as "applied" here IS the harm), so it gets
  # its own explicit row-content check rather than being folded into the
  # schema dump.
  defp migration_versions(db_name, admin_opts) do
    {:ok, conn} = Postgrex.start_link(Keyword.put(admin_opts, :database, db_name))

    %{rows: rows} =
      Postgrex.query!(conn, "SELECT version FROM schema_migrations ORDER BY version", [])

    Enum.map(rows, fn [version] -> version end)
  end

  # Round 5 (Kimi): `snapshot/1` (tables' NAMES, one specific extension, the
  # marker) is a hand-picked field list — enumerative, not complete. A
  # mutation moving `uuid_generate_v7`'s creation ahead of check!/1 passed
  # all four prior mutations unnoticed: exit code and error-message
  # assertions above still held (check!/1 still raised, just after the
  # function statement already ran), and nothing in that field list looks at
  # functions. The fix isn't a fifth field — a view, a type, or an ALTER on
  # an existing table would each need their own — it's dropping the
  # enumeration itself. `pg_dump --schema-only` serializes the database's
  # entire catalog; comparing its full text before/after makes anything
  # written between check!/1 and this assertion visible by construction, not
  # by having been anticipated in a list.
  defp schema_dump(db_name, admin_opts) do
    args = [
      "-h",
      to_string(admin_opts[:hostname]),
      "-p",
      to_string(admin_opts[:port]),
      "-U",
      admin_opts[:username],
      "--schema-only",
      "--no-owner",
      "--no-privileges",
      db_name
    ]

    {output, 0} =
      System.cmd("pg_dump", args,
        env: [{"PGPASSWORD", admin_opts[:password]}],
        stderr_to_stdout: true
      )

    # PG17's pg_dump emits a `\restrict <random-token>` / `\unrestrict
    # <same-token>` pair on every invocation — a fresh nonce gating
    # destructive psql commands on restore, unrelated to schema content.
    # Verified by hand before relying on this: three dumps of an untouched
    # database differ ONLY in this pair, and a real change (a throwaway
    # function) shows up correctly once these two lines are excluded. Left
    # in, every comparison below would fail on every run regardless of
    # whether anything actually changed — the exact flakiness a
    # whole-schema comparison was warned against introducing.
    output
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ["\\restrict ", "\\unrestrict "]))
    |> Enum.join("\n")
  end

  # A character-level `String.myers_difference/2` on two ~10K-line dumps
  # shards real SQL statements into unreadable word fragments (a single new
  # `CREATE FUNCTION` renders as a dozen `ins:` chunks a few characters
  # each). A line-set difference loses positional context but keeps every
  # changed line whole, which is what actually matters for "what got
  # written after check!/1 raised" — this is a failure message, not an
  # edit script.
  defp schema_diff_message(before_dump, after_dump) do
    before_lines = MapSet.new(String.split(before_dump, "\n"))
    after_lines = MapSet.new(String.split(after_dump, "\n"))

    added = MapSet.difference(after_lines, before_lines) |> Enum.sort()
    removed = MapSet.difference(before_lines, after_lines) |> Enum.sort()

    diff =
      Enum.map_join(added, "\n", &"+ #{&1}") <>
        if(added != [] and removed != [], do: "\n", else: "") <>
        Enum.map_join(removed, "\n", &"- #{&1}")

    "the refusal should leave the database's entire schema exactly as it found it, but " <>
      "pg_dump --schema-only shows a difference — something ran after check!/1 raised:\n#{diff}"
  end
end
