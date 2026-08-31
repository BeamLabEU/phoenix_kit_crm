defmodule Mix.Tasks.PhoenixKitCrm.ImportSuppliersFromCatalogue do
  @shortdoc "Backfill CRM companies from the catalogue's supplier list"

  @moduledoc """
  Imports catalogue suppliers into CRM companies and grants them the
  `supplier` role. This is a one-time backfill task following the
  SAP-CVI pattern.

  The machinery lives in `PhoenixKitCRM.CatalogueImport` (shared with
  `mix phoenix_kit_crm.import_manufacturers_from_catalogue` — the twin
  this flow was missing until 2026-08-31); see its moduledoc for the
  behaviour, matching logic and report format.

  ## Usage

      mix phoenix_kit_crm.import_suppliers_from_catalogue           # dry-run
      mix phoenix_kit_crm.import_suppliers_from_catalogue --apply   # write

  """

  use Mix.Task

  alias PhoenixKitCRM.CatalogueImport

  @config CatalogueImport.config(:suppliers)

  @impl Mix.Task
  def run(args), do: CatalogueImport.run(args, @config)

  # ── Public-for-testing delegators ────────────────────────────────────
  # The engine extraction (2026-08-31) kept this module's tested surface
  # stable: the test file (and any operator muscle memory) addresses
  # these by their original names.

  @doc false
  def process_supplier_row(sup, repo, prefix, apply?),
    do: CatalogueImport.process_row(sup, repo, prefix, apply?, @config)

  @doc false
  def crm_company_uuid_column?(repo, prefix),
    do: CatalogueImport.crm_company_uuid_column?(repo, prefix, @config)

  defdelegate extract_email(text), to: CatalogueImport
  defdelegate normalize_website(url), to: CatalogueImport

  @doc false
  def print_report(results), do: CatalogueImport.print_report(results, @config)
end
