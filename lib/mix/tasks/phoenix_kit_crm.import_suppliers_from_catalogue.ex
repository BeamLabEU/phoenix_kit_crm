defmodule Mix.Tasks.PhoenixKitCrm.ImportSuppliersFromCatalogue do
  @shortdoc "Backfill CRM companies from the catalogue's supplier list"

  @moduledoc """
  Imports catalogue suppliers into CRM companies and grants them the `supplier`
  role. This is a one-time backfill task following the SAP-CVI pattern.

  ## Behaviour

  - **Dry-run by default**: pass `--apply` to write changes.
  - **Idempotent**: rows with a non-null `crm_company_uuid` are skipped and
    reported as `already-linked`.
  - **Catalogue-absent guard**: if `phoenix_kit_cat_suppliers` does not exist
    the task exits with a clear message rather than crashing.
  - **Inactive suppliers are still imported** (they may appear on posted
    documents); they are flagged in the report.

  ## Matching logic (per supplier row)

  1. Normalize the candidate email: regex-extract from free-text `contact_info`,
     downcase and trim.
  2. Normalize the website: strip scheme (`https?://`) and leading `www.`,
     downcase.
  3. Match an existing CRM company by email first (citext equality), then by
     normalized website if no email match. Otherwise create a new company.

  ## Usage

      mix phoenix_kit_crm.import_suppliers_from_catalogue           # dry-run
      mix phoenix_kit_crm.import_suppliers_from_catalogue --apply   # write

  """

  use Mix.Task

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.{Companies, PartyRoles}
  alias PhoenixKitCRM.Schemas.Company

  @impl Mix.Task
  def run(args) do
    apply? = "--apply" in args

    Mix.Task.run("app.start")

    repo = RepoHelper.repo()
    prefix = Application.get_env(:phoenix_kit, :prefix, "public")

    unless catalogue_table_exists?(repo, prefix) do
      Mix.shell().error(
        "Catalogue not installed: table #{prefix}.phoenix_kit_cat_suppliers not found. " <>
          "Enable the Catalogue module first."
      )

      exit({:shutdown, 1})
    end

    unless crm_company_uuid_column?(repo, prefix) do
      Mix.shell().error(
        "phoenix_kit_cat_suppliers.crm_company_uuid is missing — the column is added " <>
          "by core migration V149. Upgrade the phoenix_kit dependency and run " <>
          "mix phoenix_kit.update first."
      )

      exit({:shutdown, 1})
    end

    suppliers = fetch_suppliers(repo, prefix)

    if suppliers == [] do
      Mix.shell().info("No catalogue suppliers found. Nothing to import.")
    else
      mode_label = if apply?, do: "APPLY", else: "DRY-RUN"

      Mix.shell().info(
        "\n[#{mode_label}] Importing #{length(suppliers)} catalogue supplier(s)...\n"
      )

      results = Enum.map(suppliers, &process_supplier_row(&1, repo, prefix, apply?))
      print_report(results)
    end
  end

  # ── Catalogue read helpers ───────────────────────────────────────────

  defp catalogue_table_exists?(repo, prefix) do
    %{rows: [[result]]} =
      repo.query!(
        "SELECT to_regclass($1) IS NOT NULL",
        ["#{prefix}.phoenix_kit_cat_suppliers"]
      )

    result
  end

  defp fetch_suppliers(repo, prefix) do
    table = "#{prefix}.phoenix_kit_cat_suppliers"

    %{rows: rows, columns: cols} =
      repo.query!("""
      SELECT uuid, name, status, contact_info, website, notes, crm_company_uuid
      FROM #{table}
      ORDER BY name ASC
      """)

    col_idx = cols |> Enum.with_index() |> Map.new(fn {c, i} -> {c, i} end)

    Enum.map(rows, fn row ->
      %{
        uuid: at(row, col_idx, "uuid"),
        name: at(row, col_idx, "name"),
        status: at(row, col_idx, "status"),
        contact_info: at(row, col_idx, "contact_info"),
        website: at(row, col_idx, "website"),
        notes: at(row, col_idx, "notes"),
        crm_company_uuid: at(row, col_idx, "crm_company_uuid")
      }
    end)
  end

  defp at(row, idx_map, col), do: Enum.at(row, Map.fetch!(idx_map, col))

  # ── Per-supplier processing ──────────────────────────────────────────

  @doc false
  # Public for testing — processes a single supplier map through match/create
  # logic and optionally writes changes. Returns a result map describing the
  # action taken.
  def process_supplier_row(sup, repo, prefix, apply?) do
    if already_linked?(sup) do
      %{
        name: sup.name,
        status: sup.status,
        uuid: sup.uuid,
        action: :already_linked,
        company_uuid: sup.crm_company_uuid
      }
    else
      do_process_supplier(sup, repo, prefix, apply?)
    end
  rescue
    e ->
      # One bad row (grant failure, duplicate-email raise, stamp error) must
      # not abort the run and suppress the report for the rows already done.
      %{
        name: sup.name,
        status: sup.status,
        uuid: sup.uuid,
        action: :error,
        company_uuid: nil,
        error: Exception.message(e)
      }
  end

  @doc false
  def crm_company_uuid_column?(repo, prefix) do
    %{rows: [[exists]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = $1
          AND table_name = 'phoenix_kit_cat_suppliers'
          AND column_name = 'crm_company_uuid'
        )
        """,
        [prefix]
      )

    exists
  end

  defp already_linked?(%{crm_company_uuid: uuid}) when is_binary(uuid) and uuid != "", do: true
  defp already_linked?(_), do: false

  defp do_process_supplier(sup, repo, prefix, apply?) do
    candidate_email = extract_email(sup.contact_info)
    candidate_website = normalize_website(sup.website)

    {action, company} =
      match_or_create_company(sup, candidate_email, candidate_website, apply?)

    if apply? && company do
      :ok = grant_supplier_role(company)
      stamp_crm_uuid(repo, prefix, sup.uuid, company.uuid)
    end

    %{
      name: sup.name,
      status: sup.status,
      uuid: sup.uuid,
      action: action,
      company_uuid: if(company, do: company.uuid, else: nil)
    }
  end

  defp match_or_create_company(sup, candidate_email, candidate_website, apply?) do
    case find_company_by_email(candidate_email) do
      %Company{} = c -> {:matched_by_email, c}
      nil -> match_by_website_or_create(sup, candidate_email, candidate_website, apply?)
    end
  end

  defp match_by_website_or_create(sup, candidate_email, candidate_website, apply?) do
    case find_company_by_website(candidate_website) do
      %Company{} = c -> {:matched_by_website, c}
      nil -> maybe_create_company(sup, candidate_email, apply?)
    end
  end

  defp maybe_create_company(_sup, _candidate_email, false), do: {:would_create, nil}

  defp maybe_create_company(sup, candidate_email, true) do
    case create_company_from_supplier(sup, candidate_email) do
      {:ok, c} -> {:created, c}
      # Return nil as company so the apply? && company guard in do_process_supplier
      # short-circuits; the caller only records the action atom in the report.
      {:error, _cs} -> {:error_creating, nil}
    end
  end

  defp find_company_by_email(nil), do: nil
  defp find_company_by_email(""), do: nil

  defp find_company_by_email(email) do
    # lower() on both sides: correct on any core version (V151 makes the column
    # citext, but older installs are plain varchar). Trashed companies are
    # excluded (CRM-wide convention); duplicate emails (the column carries no
    # unique constraint) resolve to the oldest match instead of raising.
    import Ecto.Query

    Company
    |> where([c], fragment("lower(?)", c.email) == ^String.downcase(email))
    |> where([c], c.status != "trashed")
    |> order_by([c], asc: c.inserted_at)
    |> limit(1)
    |> RepoHelper.repo().one()
  end

  defp find_company_by_website(nil), do: nil
  defp find_company_by_website(""), do: nil

  defp find_company_by_website(norm_website) do
    find_company_by_website(norm_website, Application.get_env(:phoenix_kit, :prefix, "public"))
  end

  defp find_company_by_website(norm_website, prefix) when is_binary(prefix) do
    # Match by normalized website: strip scheme+www from the stored website column
    # and compare with the already-normalized input. Raw SQL is used here because
    # Ecto fragments interpret '?' as bind-parameter placeholders, colliding with
    # the '?' regex quantifier in '^https?://'.
    table = "#{prefix}.phoenix_kit_crm_companies"

    sql = """
    SELECT uuid FROM #{table}
    WHERE regexp_replace(regexp_replace(lower(website), '^https?://', ''), '^www\\.', '')
          = $1
    AND status != 'trashed'
    LIMIT 1
    """

    case RepoHelper.repo().query!(sql, [norm_website]) do
      %{rows: [[uuid] | _]} -> RepoHelper.repo().get(Company, uuid)
      _ -> nil
    end
  end

  defp create_company_from_supplier(sup, candidate_email) do
    Companies.create_company(%{
      "name" => sup.name,
      "email" => candidate_email,
      "website" => sup.website,
      "notes" => sup.notes,
      "metadata" => %{
        "imported_from" => "cat_suppliers",
        "cat_supplier_uuid" => sup.uuid
      }
    })
  end

  defp grant_supplier_role(%Company{} = company) do
    case PartyRoles.grant_role(company, "supplier") do
      {:ok, _} -> :ok
      {:error, cs} -> raise "Failed to grant supplier role: #{inspect(cs.errors)}"
    end
  end

  defp stamp_crm_uuid(repo, prefix, supplier_uuid, company_uuid) do
    table = "#{prefix}.phoenix_kit_cat_suppliers"

    repo.query!(
      "UPDATE #{table} SET crm_company_uuid = $1 WHERE uuid = $2",
      [dump_uuid(company_uuid), dump_uuid(supplier_uuid)]
    )
  end

  # Raw SQL means no Ecto type casting: a `uuid` parameter has to be the
  # 16-byte binary, and a text uuid raises "expected a binary of 16 bytes".
  # The companion of `display_uuid/1` on the read side — this task moves uuids
  # in both directions across that boundary, and had it wrong both ways.
  defp dump_uuid(nil), do: nil
  defp dump_uuid(<<_::128>> = raw), do: raw

  defp dump_uuid(text) when is_binary(text) do
    case Ecto.UUID.dump(text) do
      {:ok, raw} -> raw
      :error -> text
    end
  end

  # ── Normalization helpers (public — tested independently) ────────────

  @doc """
  Extracts the first email-like token from a free-text contact_info string.
  Returns the downcased, trimmed email or nil.
  """
  @spec extract_email(String.t() | nil) :: String.t() | nil
  def extract_email(nil), do: nil
  def extract_email(""), do: nil

  def extract_email(text) when is_binary(text) do
    # Simple but robust email regex — matches the most common formats in
    # free-text contact fields without the full RFC 5321 complexity.
    case Regex.run(~r/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/, text) do
      [match | _] -> match |> String.downcase() |> String.trim()
      nil -> nil
    end
  end

  @doc """
  Strips `https?://` scheme and leading `www.` from a URL, then downcases.
  Returns nil for nil/empty input.
  """
  @spec normalize_website(String.t() | nil) :: String.t() | nil
  def normalize_website(nil), do: nil
  def normalize_website(""), do: nil

  def normalize_website(url) when is_binary(url) do
    url
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/^https?:\/\//, "")
    |> String.replace(~r/^www\./, "")
  end

  # ── Report rendering ─────────────────────────────────────────────────

  @doc false
  # Public for testing — renders the per-row table + totals footer.
  def print_report(results) do
    name_w = 30
    status_w = 10
    action_w = 18
    uuid_w = 38

    header =
      "#{pad("Name", name_w)} #{pad("Status", status_w)} #{pad("Action", action_w)} #{pad("Company UUID", uuid_w)}"

    divider = String.duplicate("-", name_w + status_w + action_w + uuid_w + 3)

    Mix.shell().info(header)
    Mix.shell().info(divider)

    for r <- results do
      action_label = action_label(r.action)
      inactive_flag = if r.status != "active", do: " *", else: ""

      Mix.shell().info(
        "#{pad(trunc_str(r.name, name_w - 1), name_w)} " <>
          "#{pad((r.status || "") <> inactive_flag, status_w)} " <>
          "#{pad(action_label, action_w)} " <>
          "#{display_uuid(r.company_uuid) || "(dry-run)"}"
      )
    end

    Mix.shell().info(divider)

    counts =
      results
      |> Enum.group_by(& &1.action)
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    total = length(results)
    already = Map.get(counts, :already_linked, 0)
    created = Map.get(counts, :created, 0)
    matched_email = Map.get(counts, :matched_by_email, 0)
    matched_web = Map.get(counts, :matched_by_website, 0)
    would_create = Map.get(counts, :would_create, 0)
    # :error_creating comes from a failed create-company changeset; :error is a
    # rescued exception (grant/stamp failure) from process_supplier_row/4 — both
    # are failures the operator needs reflected in the total, not just the row.
    errors = Map.get(counts, :error_creating, 0) + Map.get(counts, :error, 0)

    Mix.shell().info(
      "\nTotal: #{total} | already-linked: #{already} | created: #{created} | " <>
        "matched-email: #{matched_email} | matched-website: #{matched_web} | " <>
        "would-create (dry-run): #{would_create} | errors: #{errors}"
    )

    if Enum.any?(results, &(&1.status != "active")) do
      Mix.shell().info("  * inactive supplier — imported for document traceability")
    end
  end

  defp action_label(:already_linked), do: "already-linked"
  defp action_label(:matched_by_email), do: "matched-by-email"
  defp action_label(:matched_by_website), do: "matched-by-website"
  defp action_label(:created), do: "created"
  defp action_label(:would_create), do: "would-create"
  defp action_label(:error_creating), do: "ERROR"
  defp action_label(:error), do: "ERROR"
  defp action_label(other), do: to_string(other)

  # The supplier rows are read with raw SQL, and Postgrex hands back a `uuid`
  # column as its 16-byte binary rather than the canonical text form. Printing
  # that straight to IO raises ArgumentError — which nothing noticed until the
  # first supplier was actually linked, because the crash only happens on rows
  # that HAVE a `crm_company_uuid` and there were none anywhere.
  defp display_uuid(nil), do: nil

  defp display_uuid(<<_::128>> = raw) do
    case Ecto.UUID.load(raw) do
      {:ok, text} -> text
      :error -> Base.encode16(raw, case: :lower)
    end
  end

  defp display_uuid(text) when is_binary(text), do: text

  defp pad(str, width) do
    str = str || ""
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end

  defp trunc_str(str, max) when is_binary(str) and byte_size(str) > max,
    do: String.slice(str, 0, max - 1) <> "…"

  defp trunc_str(str, _max), do: str || ""
end
