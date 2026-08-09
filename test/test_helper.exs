# When `mix test` runs in a non-test env (e.g. default dev env in this repo),
# the test/support compiled modules live in _build/test/ebin which is not on
# the code path. Add it explicitly so TestRepo and DataCase are loadable.
test_support_ebin =
  Path.join([File.cwd!(), "_build", "test", "lib", "phoenix_kit_crm", "ebin"])

if File.dir?(test_support_ebin) do
  :code.add_patha(to_charlist(test_support_ebin))
end

alias PhoenixKitCRM.Test.Repo, as: TestRepo

db_config = Application.get_env(:phoenix_kit_crm, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_crm_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n  Test database "#{db_name}" not found — integration tests excluded.
       Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()
      TestRepo.query!("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

      TestRepo.query!("""
      CREATE OR REPLACE FUNCTION uuid_generate_v7()
      RETURNS uuid AS $$
      DECLARE
        unix_ts_ms bytea;
        uuid_bytes bytea;
      BEGIN
        unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
        uuid_bytes := unix_ts_ms || gen_random_bytes(10);
        uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
        uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
        RETURN encode(uuid_bytes, 'hex')::uuid;
      END;
      $$ LANGUAGE plpgsql VOLATILE;
      """)

      # Apply core's versioned migrations (including the CRM tables) so the
      # integration suite has a schema. Without this the test DB is empty and
      # every integration test fails on its first INSERT.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      # Record whether the resolved core actually shipped the CRM tables (its V138
      # migration). Without PHOENIX_KIT_PATH the suite resolves the *published*
      # core, which doesn't have them yet — so the integration + LiveView tests get
      # excluded (with a hint) instead of failing on a missing relation.
      %{rows: [[crm_tables?]]} =
        TestRepo.query!(
          "SELECT EXISTS (SELECT 1 FROM information_schema.tables " <>
            "WHERE table_name = 'phoenix_kit_crm_contacts')"
        )

      Application.put_env(:phoenix_kit_crm, :crm_tables_present, crm_tables?)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n  Could not connect to test database — integration tests excluded.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_crm, :test_repo_available, repo_available)

# The integration + LiveView tests need a core that has the CRM tables (V138).
# When the DB is up but the resolved core lacks them (the published core, i.e. no
# PHOENIX_KIT_PATH), exclude those tests with a clear hint instead of failing on a
# missing relation.
crm_tables_present =
  repo_available and Application.get_env(:phoenix_kit_crm, :crm_tables_present, false)

if repo_available and not crm_tables_present do
  IO.puts("""
  \n  Resolved core has no CRM tables (its V138 migration isn't applied) —
     integration + LiveView tests excluded. Run against local core:
       PHOENIX_KIT_PATH=../phoenix_kit mix test
  """)
end

{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

# Force PhoenixKit's URL prefix to "/" so Paths.*/Routes.path produce URLs the
# test router can match. Admin paths always get the default locale ("en") prefix,
# so the test router scope is `/en/admin/crm`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

i18n_api_available =
  Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
    function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1)

unless i18n_api_available do
  require Logger

  Logger.info(
    "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
      "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
      "upgraded to a release that ships the gettext_backend API."
  )
end

# The ImportSuppliersFromCatalogue integration tests additionally need the
# ecommerce catalogue table (phoenix_kit_cat_suppliers) with the
# crm_company_uuid backfill column (core >= 1.7.197). The test DB only carries
# core's own migrations, so probe for it and exclude the tag when absent —
# same pattern as the :integration exclusion above.
catalogue_available =
  crm_tables_present and
    try do
      %{rows: [[v]]} =
        TestRepo.query!(
          "SELECT EXISTS (SELECT 1 FROM information_schema.columns " <>
            "WHERE table_name = 'phoenix_kit_cat_suppliers' " <>
            "AND column_name = 'crm_company_uuid')"
        )

      v
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end

if crm_tables_present and not catalogue_available do
  IO.puts("""
  \n  cat_suppliers/crm_company_uuid absent in the test DB —
     ImportSuppliersFromCatalogue integration tests excluded.
  """)
end

exclude =
  [
    if(!repo_available or !crm_tables_present, do: :integration),
    if(!i18n_api_available, do: :requires_phoenix_kit_i18n_api),
    if(!catalogue_available, do: :requires_catalogue)
  ]
  |> Enum.reject(&is_nil/1)

# Start the test Endpoint so Phoenix.LiveViewTest can drive the CRM LiveViews via
# `live/2`. Runs with `server: false` (no port). Only when the LiveView tests will
# actually run (DB up + CRM tables present), since they're tagged :integration.
if repo_available and crm_tables_present do
  # Phoenix.LiveViewTest's file_input/render_upload joins a real Phoenix
  # Channel under the hood to track upload progress, which needs the
  # endpoint's own :pubsub_server running (independent of PhoenixKit's
  # internal PubSub.Manager, which is unrelated).
  {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PhoenixKitCRM.Test.PubSub)
  {:ok, _} = PhoenixKitCRM.Test.Endpoint.start_link()
end

# Quiet the expected "Failed to query setting …" OwnershipError noise: background
# processes (module registry / locale resolution) occasionally query settings
# without a sandbox connection during tests. Core handles these gracefully
# (returns the default); they're log spam, not failures.
:logger.add_primary_filter(
  :phoenix_kit_crm_drop_settings_noise,
  {fn log_event, _extra ->
     msg =
       case log_event do
         %{msg: {:string, m}} ->
           IO.iodata_to_binary(m)

         %{msg: {fmt, args}} when is_list(fmt) ->
           fmt |> :io_lib.format(args) |> IO.iodata_to_binary()

         _ ->
           ""
       end

     if String.contains?(msg, "Failed to query"), do: :stop, else: :ignore
   end, []}
)

ExUnit.start(exclude: exclude)
