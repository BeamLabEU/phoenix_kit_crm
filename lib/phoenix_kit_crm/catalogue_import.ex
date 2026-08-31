defmodule PhoenixKitCRM.CatalogueImport do
  @moduledoc """
  The shared engine behind the catalogue → CRM party backfill tasks
  (`mix phoenix_kit_crm.import_suppliers_from_catalogue` and
  `mix phoenix_kit_crm.import_manufacturers_from_catalogue`).

  Suppliers got this backfill when the federation shipped; manufacturers
  were forgotten and the client kept seeing the catalogue's old local
  list with nothing in the CRM UI (2026-08-31 report). The two flows are
  the same SAP-CVI-shaped promotion — read the catalogue's local rows,
  match-or-create a CRM company, grant the party role, stamp the
  `crm_company_uuid` cross-reference back — so the machinery lives here
  once, parameterized by `config/1`, and each mix task is a thin wrapper.

  ## Behaviour (both tasks)

  - **Dry-run by default**: `--apply` writes.
  - **Idempotent**: rows with a non-null `crm_company_uuid` are skipped
    and reported as `already-linked`.
  - **Catalogue-absent guard**: a missing source table exits with a
    clear message rather than crashing.
  - **Inactive rows are still imported** (they may appear on posted
    documents); flagged in the report.

  ## Matching logic (per row)

  1. Normalize the candidate email: regex-extract from free-text
     `contact_info`, downcase and trim.
  2. Normalize the website: strip scheme (`https?://`) and leading
     `www.`, downcase.
  3. Match an existing CRM company by email first (citext equality),
     then by normalized website; otherwise create a new company.
  """

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.{Companies, PartyRoles}
  alias PhoenixKitCRM.Schemas.Company

  @doc """
  The per-flow configuration. `:suppliers` is the original backfill's
  shape; `:manufacturers` is its twin (its source table also carries
  `description` and `logo_url` — `description` rides into the company
  metadata, since a CRM company has no such column).
  """
  def config(:suppliers) do
    %{
      table: "phoenix_kit_cat_suppliers",
      role: "supplier",
      noun: "supplier",
      extra_columns: [],
      metadata_source: "cat_suppliers",
      metadata_uuid_key: "cat_supplier_uuid",
      column_hint:
        "the column is added by core migration V149. Upgrade the phoenix_kit " <>
          "dependency and run mix phoenix_kit.update first."
    }
  end

  def config(:manufacturers) do
    %{
      table: "phoenix_kit_cat_manufacturers",
      role: "manufacturer",
      noun: "manufacturer",
      extra_columns: ["description"],
      metadata_source: "cat_manufacturers",
      metadata_uuid_key: "cat_manufacturer_uuid",
      column_hint:
        "the column is added by core migration V178 (the manufacturer half of " <>
          "the party federation). Upgrade the phoenix_kit dependency and run " <>
          "mix phoenix_kit.update first."
    }
  end

  @doc "The mix-task entry point: guards, fetch, process, report."
  def run(args, config) do
    apply? = "--apply" in args

    Mix.Task.run("app.start")

    repo = RepoHelper.repo()
    prefix = Application.get_env(:phoenix_kit, :prefix, "public")

    unless source_table_exists?(repo, prefix, config) do
      Mix.shell().error(
        "Catalogue not installed: table #{prefix}.#{config.table} not found. " <>
          "Enable the Catalogue module first."
      )

      exit({:shutdown, 1})
    end

    unless crm_company_uuid_column?(repo, prefix, config) do
      Mix.shell().error("#{config.table}.crm_company_uuid is missing — #{config.column_hint}")

      exit({:shutdown, 1})
    end

    rows = fetch_rows(repo, prefix, config)

    if rows == [] do
      Mix.shell().info("No catalogue #{config.noun}s found. Nothing to import.")
    else
      mode_label = if apply?, do: "APPLY", else: "DRY-RUN"

      Mix.shell().info(
        "\n[#{mode_label}] Importing #{length(rows)} catalogue #{config.noun}(s)...\n"
      )

      results = Enum.map(rows, &process_row(&1, repo, prefix, apply?, config))
      print_report(results, config)
    end
  end

  # ── Catalogue read helpers ───────────────────────────────────────────

  defp source_table_exists?(repo, prefix, config) do
    %{rows: [[result]]} =
      repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{config.table}"])

    result
  end

  @doc "Public for testing — whether the source table carries the xref column."
  def crm_company_uuid_column?(repo, prefix, config) do
    %{rows: [[exists]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = $1
          AND table_name = $2
          AND column_name = 'crm_company_uuid'
        )
        """,
        [prefix, config.table]
      )

    exists
  end

  defp fetch_rows(repo, prefix, config) do
    base_cols = ~w(uuid name status contact_info website notes crm_company_uuid)
    cols = base_cols ++ config.extra_columns

    %{rows: rows, columns: returned} =
      repo.query!("""
      SELECT #{Enum.join(cols, ", ")}
      FROM #{prefix}.#{config.table}
      ORDER BY name ASC
      """)

    col_idx = returned |> Enum.with_index() |> Map.new(fn {c, i} -> {c, i} end)

    Enum.map(rows, fn row ->
      base = %{
        uuid: display_uuid(at(row, col_idx, "uuid")),
        name: at(row, col_idx, "name"),
        status: at(row, col_idx, "status"),
        contact_info: at(row, col_idx, "contact_info"),
        website: at(row, col_idx, "website"),
        notes: at(row, col_idx, "notes"),
        crm_company_uuid: display_uuid(at(row, col_idx, "crm_company_uuid"))
      }

      Enum.reduce(config.extra_columns, base, fn col, acc ->
        Map.put(acc, String.to_existing_atom(col), at(row, col_idx, col))
      end)
    end)
  end

  defp at(row, idx_map, col), do: Enum.at(row, Map.fetch!(idx_map, col))

  # ── Per-row processing ───────────────────────────────────────────────

  @doc """
  Public for testing — processes a single source-row map through the
  match/create logic and optionally writes changes. Returns a result map
  describing the action taken.
  """
  def process_row(row, repo, prefix, apply?, config) do
    # fetch_rows/3 already runs uuids through display_uuid/1, but this
    # function is also the public-for-testing write path. A raw Postgrex
    # uuid in metadata cannot encode as JSONB — normalize here so every
    # caller is safe, not just the mix-task read path.
    row =
      row
      |> Map.replace(:uuid, display_uuid(Map.get(row, :uuid)))
      |> Map.replace(:crm_company_uuid, display_uuid(Map.get(row, :crm_company_uuid)))

    if already_linked?(row) do
      %{
        name: row.name,
        status: row.status,
        uuid: row.uuid,
        action: :already_linked,
        company_uuid: row.crm_company_uuid
      }
    else
      do_process_row(row, repo, prefix, apply?, config)
    end
  rescue
    e ->
      # One bad row (grant failure, duplicate-email raise, stamp error)
      # must not abort the run and suppress the report for the rows
      # already done.
      %{
        name: row.name,
        status: row.status,
        uuid: row.uuid,
        action: :error,
        company_uuid: nil,
        error: Exception.message(e)
      }
  end

  defp already_linked?(%{crm_company_uuid: uuid}) when is_binary(uuid) and uuid != "", do: true
  defp already_linked?(_), do: false

  defp do_process_row(row, repo, prefix, apply?, config) do
    candidate_email = extract_email(row.contact_info)
    candidate_website = normalize_website(row.website)

    {action, company} =
      match_or_create_company(row, candidate_email, candidate_website, apply?, config)

    if apply? && company do
      :ok = grant_role(company, config)
      stamp_crm_uuid(repo, prefix, row.uuid, company.uuid, config)
    end

    %{
      name: row.name,
      status: row.status,
      uuid: row.uuid,
      action: action,
      company_uuid: if(company, do: company.uuid, else: nil)
    }
  end

  defp match_or_create_company(row, candidate_email, candidate_website, apply?, config) do
    case find_company_by_email(candidate_email) do
      %Company{} = c -> {:matched_by_email, c}
      nil -> match_by_website_or_create(row, candidate_email, candidate_website, apply?, config)
    end
  end

  defp match_by_website_or_create(row, candidate_email, candidate_website, apply?, config) do
    case find_company_by_website(candidate_website) do
      %Company{} = c -> {:matched_by_website, c}
      nil -> maybe_create_company(row, candidate_email, apply?, config)
    end
  end

  defp maybe_create_company(_row, _candidate_email, false, _config), do: {:would_create, nil}

  defp maybe_create_company(row, candidate_email, true, config) do
    case create_company_from_row(row, candidate_email, config) do
      {:ok, c} -> {:created, c}
      # Return nil as company so the apply? && company guard in
      # do_process_row short-circuits; the caller only records the
      # action atom in the report.
      {:error, _cs} -> {:error_creating, nil}
    end
  end

  defp find_company_by_email(nil), do: nil
  defp find_company_by_email(""), do: nil

  defp find_company_by_email(email) do
    # lower() on both sides: correct on any core version (V151 makes the
    # column citext, but older installs are plain varchar). Trashed
    # companies are excluded (CRM-wide convention); duplicate emails
    # (the column carries no unique constraint) resolve to the oldest
    # match instead of raising.
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
    # Match by normalized website: strip scheme+www from the stored
    # website column and compare with the already-normalized input. Raw
    # SQL because Ecto fragments interpret '?' as bind-parameter
    # placeholders, colliding with the '?' regex quantifier in
    # '^https?://'.
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

  defp create_company_from_row(row, candidate_email, config) do
    metadata =
      %{
        "imported_from" => config.metadata_source,
        config.metadata_uuid_key => row.uuid
      }
      |> maybe_put_metadata("description", Map.get(row, :description))

    Companies.create_company(%{
      "name" => row.name,
      "email" => candidate_email,
      "website" => row.website,
      "notes" => row.notes,
      "metadata" => metadata
    })
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, ""), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp grant_role(%Company{} = company, config) do
    case PartyRoles.grant_role(company, config.role) do
      {:ok, _} -> :ok
      {:error, cs} -> raise "Failed to grant #{config.role} role: #{inspect(cs.errors)}"
    end
  end

  defp stamp_crm_uuid(repo, prefix, row_uuid, company_uuid, config) do
    repo.query!(
      "UPDATE #{prefix}.#{config.table} SET crm_company_uuid = $1 WHERE uuid = $2",
      [dump_uuid(company_uuid), dump_uuid(row_uuid)]
    )
  end

  # Raw SQL means no Ecto type casting: a `uuid` parameter has to be the
  # 16-byte binary, and a text uuid raises "expected a binary of 16
  # bytes". The companion of `display_uuid/1` on the read side — this
  # engine moves uuids in both directions across that boundary, and the
  # original task had it wrong both ways.
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
  Extracts the first email-like token from a free-text contact_info
  string. Returns the downcased, trimmed email or nil.
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
  Strips `https?://` scheme and leading `www.` from a URL, then
  downcases. Returns nil for nil/empty input.
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

  @doc "Public for testing — renders the per-row table + totals footer."
  def print_report(results, config) do
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
    # :error_creating comes from a failed create-company changeset;
    # :error is a rescued exception (grant/stamp failure) from
    # process_row/5 — both are failures the operator needs reflected in
    # the total, not just the row.
    errors = Map.get(counts, :error_creating, 0) + Map.get(counts, :error, 0)

    Mix.shell().info(
      "\nTotal: #{total} | already-linked: #{already} | created: #{created} | " <>
        "matched-email: #{matched_email} | matched-website: #{matched_web} | " <>
        "would-create (dry-run): #{would_create} | errors: #{errors}"
    )

    if Enum.any?(results, &(&1.status != "active")) do
      Mix.shell().info("  * inactive #{config.noun} — imported for document traceability")
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

  # The source rows are read with raw SQL, and Postgrex hands back a
  # `uuid` column as its 16-byte binary rather than the canonical text
  # form. Printing that straight to IO raises ArgumentError — which
  # nothing noticed until the first row was actually linked, because the
  # crash only happens on rows that HAVE a `crm_company_uuid` and there
  # were none anywhere.
  @doc false
  def display_uuid(nil), do: nil

  def display_uuid(<<_::128>> = raw) do
    case Ecto.UUID.load(raw) do
      {:ok, text} -> text
      :error -> Base.encode16(raw, case: :lower)
    end
  end

  def display_uuid(text) when is_binary(text), do: text

  defp pad(str, width) do
    str = str || ""
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end

  defp trunc_str(str, max) when is_binary(str) and byte_size(str) > max,
    do: String.slice(str, 0, max - 1) <> "…"

  defp trunc_str(str, _max), do: str || ""
end
