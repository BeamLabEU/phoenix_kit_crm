defmodule Mix.Tasks.PhoenixKitCrm.ImportManufacturersFromCatalogueTest do
  @moduledoc """
  Tests for the import_manufacturers_from_catalogue Mix task — the twin
  the supplier backfill shipped without (client report, 2026-08-31).

  The engine (`PhoenixKitCRM.CatalogueImport`) is exhaustively covered
  by the supplier task's test file through its delegators; this file
  pins what the MANUFACTURER config changes — source table, role,
  metadata keys, and the description ride-along — plus idempotency on
  that path. Same `:integration` + `:requires_catalogue` gating.
  """

  defmodule ConfigTest do
    use ExUnit.Case, async: true

    alias PhoenixKitCRM.CatalogueImport

    test "the manufacturer config names its own table, role and metadata keys" do
      config = CatalogueImport.config(:manufacturers)

      assert config.table == "phoenix_kit_cat_manufacturers"
      assert config.role == "manufacturer"
      assert config.metadata_source == "cat_manufacturers"
      assert config.metadata_uuid_key == "cat_manufacturer_uuid"
      assert "description" in config.extra_columns
      # The guard message must point at the migration that actually adds
      # this table's xref column (V178, not the suppliers' V149).
      assert config.column_hint =~ "V178"
    end
  end

  defmodule IntegrationTest do
    use PhoenixKitCRM.DataCase, async: false

    alias Ecto.Adapters.SQL.Sandbox
    alias PhoenixKit.RepoHelper
    alias PhoenixKitCRM.CatalogueImport
    alias PhoenixKitCRM.{Companies, PartyRoles}

    @moduletag :integration
    @moduletag :requires_catalogue

    @config CatalogueImport.config(:manufacturers)

    setup_all do
      repo = RepoHelper.repo()
      prefix = Application.get_env(:phoenix_kit, :prefix, "public")

      # Same probe discipline as the supplier task's test file: manual
      # sandbox mode means no connection unless we own one, and
      # ownership failures arrive as EXITs.
      owner = Sandbox.start_owner!(repo, shared: false)

      try do
        table_exists? =
          try do
            %{rows: [[result]]} =
              repo.query!(
                "SELECT to_regclass($1) IS NOT NULL",
                ["#{prefix}.phoenix_kit_cat_manufacturers"]
              )

            result
          rescue
            _ -> false
          catch
            :exit, _ -> false
          end

        column_exists? =
          table_exists? and
            try do
              CatalogueImport.crm_company_uuid_column?(repo, prefix, @config)
            rescue
              _ -> false
            catch
              :exit, _ -> false
            end

        unless column_exists? do
          IO.puts(
            "\n  cat_manufacturers/crm_company_uuid absent (needs core >= V178) — " <>
              "ImportManufacturersFromCatalogue integration tests skipped.\n"
          )
        end

        {:ok, catalogue_available: column_exists?, prefix: prefix}
      after
        Sandbox.stop_owner(owner)
      end
    end

    setup %{catalogue_available: available} = ctx do
      if available do
        {:ok, Map.put(ctx, :repo, RepoHelper.repo())}
      else
        {:ok, Map.put(ctx, :skip_all, true)}
      end
    end

    defp uuid_to_binary(<<_::128>> = raw), do: raw

    defp uuid_to_binary(text) when is_binary(text) do
      {:ok, raw} = Ecto.UUID.dump(text)
      raw
    end

    defp uuid_to_text(nil), do: nil
    defp uuid_to_text(text) when is_binary(text) and byte_size(text) != 16, do: text

    defp uuid_to_text(<<_::128>> = raw) do
      {:ok, text} = Ecto.UUID.load(raw)
      text
    end

    defp insert_manufacturer(repo, prefix, attrs) do
      table = "#{prefix}.phoenix_kit_cat_manufacturers"
      uuid = Ecto.UUID.generate()
      name = attrs[:name] || "Test Manufacturer #{uuid}"

      repo.query!(
        """
        INSERT INTO #{table}
          (uuid, name, status, contact_info, website, notes, description, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), NOW())
        """,
        [
          uuid_to_binary(uuid),
          name,
          attrs[:status] || "active",
          attrs[:contact_info],
          attrs[:website],
          attrs[:notes],
          attrs[:description]
        ]
      )

      uuid
    end

    defp delete_manufacturer(repo, prefix, uuid) do
      table = "#{prefix}.phoenix_kit_cat_manufacturers"
      repo.query!("DELETE FROM #{table} WHERE uuid = $1", [uuid_to_binary(uuid)])
    end

    defp get_crm_uuid(repo, prefix, uuid) do
      table = "#{prefix}.phoenix_kit_cat_manufacturers"

      %{rows: [[value]]} =
        repo.query!("SELECT crm_company_uuid FROM #{table} WHERE uuid = $1", [
          uuid_to_binary(uuid)
        ])

      uuid_to_text(value)
    end

    defp manufacturer_map(attrs) do
      Map.merge(
        %{
          uuid: Ecto.UUID.generate(),
          name: "Test Manufacturer",
          status: "active",
          contact_info: nil,
          website: nil,
          notes: nil,
          description: nil,
          crm_company_uuid: nil
        },
        attrs
      )
    end

    describe "apply mode" do
      test "creates company, grants MANUFACTURER role, stamps the xref, carries description",
           %{catalogue_available: true, repo: repo, prefix: prefix} do
        uniq = Ecto.UUID.generate()

        manufacturer_uuid =
          insert_manufacturer(repo, prefix, %{
            name: "Brand New Maker #{uniq}",
            contact_info: "#{uniq}@maker.example",
            description: "Premium hinge maker"
          })

        on_exit(fn -> delete_manufacturer(repo, prefix, manufacturer_uuid) end)

        row =
          manufacturer_map(%{
            uuid: manufacturer_uuid,
            name: "Brand New Maker #{uniq}",
            contact_info: "#{uniq}@maker.example",
            description: "Premium hinge maker"
          })

        result = CatalogueImport.process_row(row, repo, prefix, true, @config)

        assert result.action == :created
        assert is_binary(result.company_uuid)

        company = Companies.get_company(result.company_uuid)
        assert company
        assert company.metadata["imported_from"] == "cat_manufacturers"
        assert company.metadata["cat_manufacturer_uuid"] == manufacturer_uuid
        assert company.metadata["description"] == "Premium hinge maker"
        assert PartyRoles.has_role?(company, "manufacturer")
        refute PartyRoles.has_role?(company, "supplier")

        assert get_crm_uuid(repo, prefix, manufacturer_uuid) == result.company_uuid

        on_exit(fn -> Companies.delete_company(company) end)
      end

      test "a second run reports the stamped row as already-linked", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()

        manufacturer_uuid =
          insert_manufacturer(repo, prefix, %{
            name: "Idempotent Maker #{uniq}",
            contact_info: "#{uniq}@idem.example"
          })

        on_exit(fn -> delete_manufacturer(repo, prefix, manufacturer_uuid) end)

        row =
          manufacturer_map(%{
            uuid: manufacturer_uuid,
            name: "Idempotent Maker #{uniq}",
            contact_info: "#{uniq}@idem.example"
          })

        first = CatalogueImport.process_row(row, repo, prefix, true, @config)
        assert first.action == :created
        on_exit(fn -> Companies.delete_company(Companies.get_company(first.company_uuid)) end)

        # Re-read the stamped row the way the task's fetch does.
        second =
          CatalogueImport.process_row(
            Map.put(row, :crm_company_uuid, get_crm_uuid(repo, prefix, manufacturer_uuid)),
            repo,
            prefix,
            true,
            @config
          )

        assert second.action == :already_linked
        assert second.company_uuid == first.company_uuid
      end
    end

    describe "dry-run" do
      test "reports would-create and writes nothing", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()

        manufacturer_uuid =
          insert_manufacturer(repo, prefix, %{name: "Dry Run Maker #{uniq}"})

        on_exit(fn -> delete_manufacturer(repo, prefix, manufacturer_uuid) end)

        row = manufacturer_map(%{uuid: manufacturer_uuid, name: "Dry Run Maker #{uniq}"})
        result = CatalogueImport.process_row(row, repo, prefix, false, @config)

        assert result.action == :would_create
        assert result.company_uuid == nil
        assert get_crm_uuid(repo, prefix, manufacturer_uuid) == nil
      end
    end
  end
end
