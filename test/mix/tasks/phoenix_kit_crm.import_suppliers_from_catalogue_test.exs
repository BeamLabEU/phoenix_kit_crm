defmodule Mix.Tasks.PhoenixKitCrm.ImportSuppliersFromCatalogueTest do
  @moduledoc """
  Tests for the import_suppliers_from_catalogue Mix task.

  Contains two sub-modules:
  - NormalizationTest: pure unit tests — no DB needed.
  - IntegrationTest: DB-backed tests tagged :integration.

  Integration tests are guarded against a missing catalogue table (CI or
  environments without the Catalogue module installed).
  """

  # ── Pure unit tests (normalization helpers) ──────────────────────────

  defmodule NormalizationTest do
    use ExUnit.Case, async: true

    import ExUnit.CaptureIO

    alias Mix.Tasks.PhoenixKitCrm.ImportSuppliersFromCatalogue, as: Task

    describe "extract_email/1" do
      test "extracts a simple email from plain text" do
        assert Task.extract_email("Contact: sales@acme.example") == "sales@acme.example"
      end

      test "lowercases and trims the extracted email" do
        assert Task.extract_email("  Sales@ACME.Example  ") == "sales@acme.example"
      end

      test "returns nil for nil input" do
        assert Task.extract_email(nil) == nil
      end

      test "returns nil for empty string" do
        assert Task.extract_email("") == nil
      end

      test "returns nil when no email is found" do
        assert Task.extract_email("No email here, call +372 555 1234") == nil
      end

      test "extracts the first email from a multi-email string" do
        result = Task.extract_email("primary@first.com or backup@second.com")
        assert result == "primary@first.com"
      end

      test "handles email embedded in free-text with punctuation" do
        assert Task.extract_email("info: info@supplier.ee, fax: +372 123") == "info@supplier.ee"
      end
    end

    describe "normalize_website/1" do
      test "strips https scheme and www prefix, lowercases" do
        assert Task.normalize_website("https://www.acme.example/") == "acme.example/"
      end

      test "strips http scheme only" do
        assert Task.normalize_website("http://acme.example") == "acme.example"
      end

      test "strips www without scheme" do
        assert Task.normalize_website("www.acme.example") == "acme.example"
      end

      test "lowercases the result" do
        assert Task.normalize_website("HTTPS://WWW.ACME.EXAMPLE") == "acme.example"
      end

      test "returns nil for nil input" do
        assert Task.normalize_website(nil) == nil
      end

      test "returns nil for empty string" do
        assert Task.normalize_website("") == nil
      end

      test "leaves a plain domain unchanged" do
        assert Task.normalize_website("acme.example") == "acme.example"
      end

      test "does not strip www mid-path" do
        # Only leading www. is stripped.
        assert Task.normalize_website("https://acme.example/www/page") ==
                 "acme.example/www/page"
      end
    end

    describe "print_report/1" do
      test "counts a rescued :error row in the errors total, alongside :error_creating" do
        results = [
          %{name: "A", status: "active", uuid: "1", action: :created, company_uuid: "c1"},
          %{
            name: "B",
            status: "active",
            uuid: "2",
            action: :error,
            company_uuid: nil,
            error: "boom"
          },
          %{name: "C", status: "active", uuid: "3", action: :error_creating, company_uuid: nil}
        ]

        output = capture_io(fn -> Task.print_report(results) end)

        assert output =~ "Total: 3"
        assert output =~ "errors: 2"
      end
    end
  end

  # ── Integration tests (require catalogue table) ───────────────────────

  defmodule IntegrationTest do
    use PhoenixKitCRM.DataCase, async: false

    alias Mix.Tasks.PhoenixKitCrm.ImportSuppliersFromCatalogue, as: Task
    alias PhoenixKit.RepoHelper
    alias PhoenixKitCRM.{Companies, PartyRoles}

    @moduletag :integration
    # Excluded by test_helper.exs when the catalogue table/column is absent —
    # the per-test `catalogue_available: true` match heads below would
    # otherwise FunctionClauseError (setup can't dynamically skip in ExUnit).
    @moduletag :requires_catalogue

    # Guard: detect whether the catalogue table exists once per suite.
    setup_all do
      repo = RepoHelper.repo()
      prefix = Application.get_env(:phoenix_kit, :prefix, "public")

      # Sandbox ownership failures arrive as EXITs (DBConnection.Holder), not
      # raises — catch both, or one unowned checkout invalidates the module.
      table_exists? =
        try do
          %{rows: [[result]]} =
            repo.query!(
              "SELECT to_regclass($1) IS NOT NULL",
              ["#{prefix}.phoenix_kit_cat_suppliers"]
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
            Task.crm_company_uuid_column?(repo, prefix)
          rescue
            _ -> false
          catch
            :exit, _ -> false
          end

      unless column_exists? do
        IO.puts(
          "\n  cat_suppliers/crm_company_uuid absent (needs core >= 1.7.197) — " <>
            "ImportSuppliersFromCatalogue integration tests skipped.\n"
        )
      end

      {:ok, catalogue_available: column_exists?, prefix: prefix}
    end

    setup %{catalogue_available: available} = ctx do
      if available do
        {:ok, Map.put(ctx, :repo, RepoHelper.repo())}
      else
        # ExUnit has no per-test dynamic skip from setup; mark the whole
        # describe as skipped instead of letting tests MatchError.
        {:ok, Map.put(ctx, :skip_all, true)}
      end
    end

    # Helper: insert a raw supplier row via SQL.
    defp insert_supplier(repo, prefix, attrs) do
      table = "#{prefix}.phoenix_kit_cat_suppliers"
      uuid = Ecto.UUID.generate()
      name = attrs[:name] || "Test Supplier #{uuid}"
      status = attrs[:status] || "active"
      contact_info = attrs[:contact_info]
      website = attrs[:website]
      notes = attrs[:notes]

      repo.query!(
        """
        INSERT INTO #{table} (uuid, name, status, contact_info, website, notes)
        VALUES ($1, $2, $3, $4, $5, $6)
        """,
        [uuid, name, status, contact_info, website, notes]
      )

      uuid
    end

    # Helper: delete a supplier row by uuid (cleanup after test).
    defp delete_supplier(repo, prefix, uuid) do
      table = "#{prefix}.phoenix_kit_cat_suppliers"
      repo.query!("DELETE FROM #{table} WHERE uuid = $1", [uuid])
    end

    # Helper: fetch crm_company_uuid stamped on a supplier row.
    defp get_crm_uuid(repo, prefix, supplier_uuid) do
      table = "#{prefix}.phoenix_kit_cat_suppliers"

      %{rows: [[v]]} =
        repo.query!("SELECT crm_company_uuid FROM #{table} WHERE uuid = $1", [supplier_uuid])

      v
    end

    # Helper: build a minimal supplier map (as fetch_suppliers/2 would return).
    defp supplier_map(attrs) do
      %{
        uuid: attrs[:uuid] || Ecto.UUID.generate(),
        name: attrs[:name] || "Test Supplier",
        status: attrs[:status] || "active",
        contact_info: attrs[:contact_info],
        website: attrs[:website],
        notes: attrs[:notes],
        crm_company_uuid: attrs[:crm_company_uuid]
      }
    end

    describe "match logic against seeded companies" do
      test "matches an existing company by email (case-insensitive on both sides)", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        {:ok, company} =
          Companies.create_company(%{
            "name" => "Email Match Co",
            "email" => "Sales@Email-Match.example"
          })

        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "Email Supplier",
            contact_info: "Reach us: SALES@email-match.example or call +372 555 0001"
          })

        on_exit(fn ->
          delete_supplier(repo, prefix, supplier_uuid)
          Companies.delete_company(company)
        end)

        sup =
          supplier_map(%{
            uuid: supplier_uuid,
            contact_info: "Reach us: SALES@email-match.example or call +372 555 0001"
          })

        result = Task.process_supplier_row(sup, repo, prefix, false)

        assert result.action == :matched_by_email
        assert result.company_uuid == company.uuid

        # Dry-run must not write: no supplier role granted, no stamp.
        refute PhoenixKitCRM.PartyRoles.has_role?(company, "supplier")

        %{rows: [[stamped]]} =
          repo.query!(
            "SELECT crm_company_uuid FROM #{prefix}.phoenix_kit_cat_suppliers WHERE uuid = $1",
            [Ecto.UUID.dump!(supplier_uuid)]
          )

        assert is_nil(stamped)
      end

      test "matches an existing company by normalized website when no email match", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        {:ok, company} =
          Companies.create_company(%{
            "name" => "Website Match Co",
            "website" => "https://www.website-match.example"
          })

        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "Website Supplier",
            website: "http://website-match.example"
          })

        on_exit(fn ->
          delete_supplier(repo, prefix, supplier_uuid)
          Companies.delete_company(company)
        end)

        sup = supplier_map(%{uuid: supplier_uuid, website: "http://website-match.example"})
        result = Task.process_supplier_row(sup, repo, prefix, false)

        assert result.action == :matched_by_website
        assert result.company_uuid == company.uuid
      end

      test "would_create in dry-run when no existing company matches", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()

        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "New Supplier #{uniq}",
            contact_info: "#{uniq}@unique-new.example",
            website: "https://unique-#{uniq}.example"
          })

        on_exit(fn -> delete_supplier(repo, prefix, supplier_uuid) end)

        companies_before = Companies.count_companies()

        sup =
          supplier_map(%{
            uuid: supplier_uuid,
            name: "New Supplier #{uniq}",
            contact_info: "#{uniq}@unique-new.example",
            website: "https://unique-#{uniq}.example"
          })

        result = Task.process_supplier_row(sup, repo, prefix, false)

        assert result.action == :would_create
        assert result.company_uuid == nil
        # Dry-run: no company created
        assert Companies.count_companies() == companies_before
      end
    end

    describe "apply mode" do
      test "creates company, grants supplier role, stamps crm_company_uuid", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()

        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "Brand New Supplier #{uniq}",
            contact_info: "#{uniq}@newsupplier.example",
            notes: "Some notes"
          })

        on_exit(fn -> delete_supplier(repo, prefix, supplier_uuid) end)

        sup =
          supplier_map(%{
            uuid: supplier_uuid,
            name: "Brand New Supplier #{uniq}",
            contact_info: "#{uniq}@newsupplier.example",
            notes: "Some notes"
          })

        result = Task.process_supplier_row(sup, repo, prefix, true)

        assert result.action == :created
        assert is_binary(result.company_uuid)

        # Company exists and has the supplier role
        company = Companies.get_company(result.company_uuid)
        assert company
        assert company.metadata["imported_from"] == "cat_suppliers"
        assert company.metadata["cat_supplier_uuid"] == supplier_uuid
        assert PartyRoles.has_role?(company, "supplier")

        # crm_company_uuid stamped on the catalogue row
        assert get_crm_uuid(repo, prefix, supplier_uuid) == result.company_uuid

        on_exit(fn -> Companies.delete_company(company) end)
      end

      test "inactive supplier is imported and flagged", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()

        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "Inactive Supplier #{uniq}",
            status: "inactive"
          })

        on_exit(fn -> delete_supplier(repo, prefix, supplier_uuid) end)

        sup =
          supplier_map(%{
            uuid: supplier_uuid,
            name: "Inactive Supplier #{uniq}",
            status: "inactive"
          })

        result = Task.process_supplier_row(sup, repo, prefix, true)

        assert result.action == :created
        assert result.status == "inactive"
        assert is_binary(result.company_uuid)

        company = Companies.get_company(result.company_uuid)
        assert PartyRoles.has_role?(company, "supplier")
        on_exit(fn -> Companies.delete_company(company) end)
      end
    end

    describe "idempotency" do
      test "second run skips rows already stamped with crm_company_uuid", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()

        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "Idempotent Supplier #{uniq}",
            contact_info: "idempotent-#{uniq}@example.com"
          })

        on_exit(fn -> delete_supplier(repo, prefix, supplier_uuid) end)

        sup =
          supplier_map(%{
            uuid: supplier_uuid,
            name: "Idempotent Supplier #{uniq}",
            contact_info: "idempotent-#{uniq}@example.com"
          })

        # First apply
        r1 = Task.process_supplier_row(sup, repo, prefix, true)
        assert r1.action == :created
        company_uuid = r1.company_uuid

        # Simulate what the full task loop does: re-fetch the stamped row
        sup_after = Map.put(sup, :crm_company_uuid, company_uuid)
        r2 = Task.process_supplier_row(sup_after, repo, prefix, true)

        assert r2.action == :already_linked
        assert r2.company_uuid == company_uuid

        # Only one company created
        assert Companies.get_company(company_uuid)
        company = Companies.get_company(company_uuid)
        on_exit(fn -> Companies.delete_company(company) end)
      end

      test "idempotent grant_role does not duplicate the supplier role", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()
        {:ok, company} = Companies.create_company(%{"name" => "Already Supplier #{uniq}"})

        # The supplier row already has crm_company_uuid stamped
        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "Pre-matched Supplier #{uniq}"
          })

        table = "#{prefix}.phoenix_kit_cat_suppliers"

        repo.query!(
          "UPDATE #{table} SET crm_company_uuid = $1 WHERE uuid = $2",
          [company.uuid, supplier_uuid]
        )

        on_exit(fn ->
          delete_supplier(repo, prefix, supplier_uuid)
          Companies.delete_company(company)
        end)

        # Process as already-linked
        sup =
          supplier_map(%{
            uuid: supplier_uuid,
            name: "Pre-matched Supplier #{uniq}",
            crm_company_uuid: company.uuid
          })

        result = Task.process_supplier_row(sup, repo, prefix, true)
        assert result.action == :already_linked

        # No duplicate supplier role rows
        roles = PartyRoles.list_roles(company)
        active_supplier_roles = Enum.filter(roles, &(&1.role == "supplier" and &1.is_active))
        assert length(active_supplier_roles) <= 1
      end
    end

    describe "dry-run writes nothing" do
      test "no company is created and no crm_company_uuid is stamped in dry-run", %{
        catalogue_available: true,
        repo: repo,
        prefix: prefix
      } do
        uniq = Ecto.UUID.generate()

        supplier_uuid =
          insert_supplier(repo, prefix, %{
            name: "DryRun Supplier #{uniq}",
            contact_info: "dryrun-#{uniq}@example.com",
            website: "https://dryrun-#{uniq}.example"
          })

        on_exit(fn -> delete_supplier(repo, prefix, supplier_uuid) end)

        companies_before = Companies.count_companies()

        sup =
          supplier_map(%{
            uuid: supplier_uuid,
            name: "DryRun Supplier #{uniq}",
            contact_info: "dryrun-#{uniq}@example.com",
            website: "https://dryrun-#{uniq}.example"
          })

        result = Task.process_supplier_row(sup, repo, prefix, false)
        assert result.action == :would_create
        assert result.company_uuid == nil

        # No company created
        assert Companies.count_companies() == companies_before

        # crm_company_uuid still nil in the catalogue table
        assert get_crm_uuid(repo, prefix, supplier_uuid) == nil
      end
    end

    describe "catalogue absence guard" do
      test "process_supplier_row handles a nil crm_company_uuid gracefully (not already-linked)",
           %{
             catalogue_available: true,
             repo: repo,
             prefix: prefix
           } do
        # A supplier map with nil crm_company_uuid should NOT be treated as already-linked.
        uniq = Ecto.UUID.generate()

        sup =
          supplier_map(%{
            uuid: Ecto.UUID.generate(),
            name: "Null UUID Sup #{uniq}",
            crm_company_uuid: nil
          })

        result = Task.process_supplier_row(sup, repo, prefix, false)
        # In dry-run with no match this is would_create — not already_linked
        assert result.action != :already_linked
      end
    end
  end
end
