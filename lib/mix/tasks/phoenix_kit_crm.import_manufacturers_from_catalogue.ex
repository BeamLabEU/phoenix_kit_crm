defmodule Mix.Tasks.PhoenixKitCrm.ImportManufacturersFromCatalogue do
  @shortdoc "Backfill CRM companies from the catalogue's manufacturer list"

  @moduledoc """
  Imports catalogue manufacturers into CRM companies and grants them the
  `manufacturer` role — the twin of
  `mix phoenix_kit_crm.import_suppliers_from_catalogue`, which shipped
  with the party federation while this half was forgotten: local
  `phoenix_kit_cat_manufacturers` rows kept feeding the item form's
  dropdown as the "old list" while the CRM Companies page's
  Manufacturers filter showed nothing (client report, 2026-08-31).

  The machinery lives in `PhoenixKitCRM.CatalogueImport`; see its
  moduledoc for the behaviour, matching logic and report format. The
  manufacturer source rows also carry a `description` — it rides into
  the created company's metadata (a CRM company has no such column).

  Requires core migration V178 (`crm_company_uuid` on the manufacturers
  table — the transition cross-reference the read-side federation in
  `PhoenixKitCatalogue.Catalogue.Manufacturers.list_all/1` already
  honours: once a local row is stamped, the pickers list the CRM party
  instead of showing the company twice).

  ## Usage

      mix phoenix_kit_crm.import_manufacturers_from_catalogue           # dry-run
      mix phoenix_kit_crm.import_manufacturers_from_catalogue --apply   # write

  """

  use Mix.Task

  alias PhoenixKitCRM.CatalogueImport

  @config CatalogueImport.config(:manufacturers)

  @impl Mix.Task
  def run(args), do: CatalogueImport.run(args, @config)
end
