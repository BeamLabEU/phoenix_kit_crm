defmodule PhoenixKitCRM.Lists.Import do
  @moduledoc """
  Pure-ish CSV/plaintext import engine for CRM contact lists (Stage 3 of the
  restructuring plan — the user's stated priority: account list import).
  Parses rows, applies the restructuring spec's Locked decisions, and writes
  only through `PhoenixKitCRM.Lists` — it never duplicates that context's
  insert/counter/broadcast logic.

  ## Locked decisions this engine enforces

    * Import always creates a NEW contact — never a merge, never "add to
      existing contact by matching email". Matching duplicates across
      contacts is a separate, later, human-reviewed comparison screen
      (Stage C4c), not something this engine decides on its own.
    * Per-row atomicity: contact INSERT + membership INSERT happen in ONE
      transaction (`Lists.add_new_contact_to_list/3`) — a uniqueness
      violation rolls both back, so a failed/duplicate row never leaves an
      orphan contact behind.
    * Idempotent re-import: importing the identical file twice creates zero
      new contacts on the second pass — every row lands in `skipped`
      instead of `created`/`added` (`:already_in_list` if the existing
      membership is still active, `:unsubscribed` if a prior membership was
      removed but still holds the email slot per the DB's partial unique
      index — see `ListMember`'s moduledoc). A KNOWN collision is
      classified straight from a batched `Lists.members_by_email/3` lookup
      (one per chunk — see `run_chunk/4`) and never reaches the write
      transaction at all, so re-importing a large duplicate file doesn't
      pay an INSERT-then-rollback per colliding row; only an email the
      batched lookup didn't already know about goes through it, where a
      race against a concurrent import is still caught by the DB's own
      unique index.

  ## Row pipeline

  Each row goes through, in order: normalize (trim + downcase, matching the
  `email` column's citext case-insensitivity) → in-file dedup prefilter
  (`:duplicate_in_file` — a second row with the same email, e.g. a shared
  mailbox listed under two names, never reaches the DB) → email format
  check (`:invalid_email`) → the batched `members_by_email` lookup (a KNOWN
  collision short-circuits straight to `:already_in_list`/`:unsubscribed`,
  no write attempted) → the write transaction for anything left, which
  still classifies an `idx_crm_list_members_list_email` violation (a race
  the batched lookup couldn't have seen) by looking up the existing
  holder's status.

  `name` is CSV-optional per the spec; a blank name falls back to the email
  itself (mirrors `Contact.display_name/1`'s own fallback) so the contact
  changeset's `validate_required([:name])` never rejects an otherwise-valid
  row. `locale`, if present but not in a recognized format, is silently
  dropped rather than rejecting the row over a cosmetic field. `company`
  has no dedicated contact field yet (linking to `PhoenixKitCRM.Companies`
  is out of scope here) — it's stashed in `contact.metadata["import_company"]`
  so the comparison screen (C4c) can still surface it later instead of the
  data being silently discarded.

  ## XLSX

  Deliberately not supported yet. `xlsxir` (the library the plan asked to
  evaluate) is unmaintained since 2019 — not something to add as a new
  dependency. `xlsx_reader` is an actively-maintained alternative but wasn't
  evaluated in depth (its own dependency footprint, streaming behavior, etc.
  is a separate task). CSV/TXT cover the stated priority (account import);
  XLSX is deferred to a follow-up rather than shipped on an abandoned lib.
  """

  require Logger

  alias PhoenixKitCRM.Lists
  alias PhoenixKitCRM.Lists.ImportReport
  alias PhoenixKitCRM.Schemas.{Contact, ContactList}

  @csv_columns ~w(email name company locale)
  @locale_format ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Imports from CSV content (already read from an upload or textarea paste).
  Header row is required; column matching is case-insensitive and only
  looks for `email` (required), `name`, `company`, `locale` (all optional)
  — unrecognized columns are ignored. `opts` accepts `:actor_uuid` (passed
  through to the activity log on every successful row).
  """
  @spec import_csv(String.t(), ContactList.t(), keyword()) :: ImportReport.t()
  def import_csv(content, %ContactList{} = list, opts \\ []) do
    content
    |> parse_csv()
    |> run(list, opts)
  end

  @doc """
  Imports from plaintext/clipboard content — one email address per line.
  Blank lines are ignored. `opts` accepts `:actor_uuid`.
  """
  @spec import_text(String.t(), ContactList.t(), keyword()) :: ImportReport.t()
  def import_text(content, %ContactList{} = list, opts \\ []) do
    content
    |> parse_text()
    |> run(list, opts)
  end

  @doc """
  Parses CSV content into `{line, attrs}` rows WITHOUT writing anything —
  the same parser `import_csv/3` uses internally, exposed for the import
  UI's dry-run preview and chunked processing (`run_chunk/4`) so neither
  has to duplicate the parsing. Non-UTF-8 content and malformed CSV (e.g.
  an unterminated quote, which `NimbleCSV` raises on) return `[]` rather
  than crashing the caller.
  """
  @spec parse_csv_rows(String.t()) :: [{pos_integer(), map()}]
  def parse_csv_rows(content), do: parse_csv(content)

  @doc "Same as `parse_csv_rows/1`, for plaintext/clipboard content."
  @spec parse_text_rows(String.t()) :: [{pos_integer(), map()}]
  def parse_text_rows(content), do: parse_text(content)

  @doc """
  Puts a report's `rows` back into file order. Reports threaded through
  `run_chunk/4` accumulate rows prepended (newest first) — appending per row
  would be O(n²) on a file near the upload size limit — so a caller that
  renders row detail must finalize once when the run completes. `run/3` and
  `preview_rows/2` already return finalized reports.
  """
  @spec finalize_report(ImportReport.t()) :: ImportReport.t()
  def finalize_report(%ImportReport{} = report),
    do: %{report | rows: Enum.reverse(report.rows)}

  @doc """
  Classifies every row exactly like `import_csv/3`/`import_text/3` would,
  but performs NO writes — `:no_email`/`:invalid_email`/`:duplicate_in_file`
  are determined purely from the parsed rows, and an email that would
  collide on `idx_crm_list_members_list_email` is detected via ONE batched
  `Lists.members_by_email/2` lookup (all distinct emails in the file, one
  query) instead of attempting (and rolling back) an insert per row. A
  naive per-row `Lists.get_member_by_email/2` call here would mean tens of
  thousands of sequential round trips for a file near the upload size
  limit, blocking the LiveView process on a single, unyielding preview
  event — this is a dry-run specifically so it has to stay cheap.

  Returns the same `%ImportReport{}` shape — `created`/`added` mean "would
  be created/added" — with the full file's counts, so the caller decides
  how many of `rows` to actually render (e.g. the first 20 for a preview).

  Not a 100% guarantee of the real run's outcome: a row that fails
  `Contacts.create_contact/1`'s validation for a reason unrelated to email
  uniqueness (e.g. an oversized name) only surfaces at the real
  `import_csv/3`/`import_text/3` call, since this never attempts the
  insert.
  """
  @spec preview_rows([{pos_integer(), map()}], ContactList.t()) :: ImportReport.t()
  def preview_rows(parsed_rows, %ContactList{} = list) do
    members_by_email = Lists.members_by_email(list, distinct_emails(parsed_rows))

    {report, _seen} =
      process_all(parsed_rows, list, fn _attrs, email ->
        preview_row(email, members_by_email)
      end)

    finalize_report(report)
  end

  defp distinct_emails(parsed_rows) do
    parsed_rows
    |> Enum.map(fn {_line, attrs} -> attrs["email"] end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_email/1)
    |> Enum.uniq()
  end

  @doc "A fresh `{report, seen_emails}` accumulator to start chunked processing with `run_chunk/4`."
  @spec new_accumulator() :: {ImportReport.t(), MapSet.t()}
  def new_accumulator, do: {%ImportReport{}, MapSet.new()}

  @doc """
  Processes one slice of already-parsed rows (from `parse_csv_rows/1` /
  `parse_text_rows/1`), threading the `{report, seen_emails}` accumulator
  from `new_accumulator/0` (or a prior `run_chunk/4` call) through — so
  `:duplicate_in_file` detection and the running counts stay correct across
  chunk boundaries. Lets a caller (the import UI) process a huge file in
  chunks with a progress update between each, instead of blocking on the
  whole file in one pass. `opts` accepts `:actor_uuid`/`:source` like
  `import_csv/3`. Rows accumulate newest-first (see `finalize_report/1`) —
  call `finalize_report/1` on the report once the run completes.
  """
  @spec run_chunk(
          [{pos_integer(), map()}],
          ContactList.t(),
          keyword(),
          {ImportReport.t(), MapSet.t()}
        ) :: {ImportReport.t(), MapSet.t()}
  def run_chunk(rows_chunk, %ContactList{} = list, opts, {%ImportReport{}, %MapSet{}} = acc) do
    members_by_email = Lists.members_by_email(list, distinct_emails(rows_chunk))

    process_all(
      rows_chunk,
      list,
      fn attrs, email -> import_row(attrs, email, list, opts, members_by_email) end,
      acc
    )
  end

  # ── Parsing ─────────────────────────────────────────────────────────

  defp parse_csv(content) do
    # Guard before NimbleCSV ever sees the content: a Windows-1252/Latin-1
    # export (Excel's default in many locales) is not valid UTF-8 and would
    # either raise here or crash the INSERT downstream in Postgres, and a
    # malformed CSV (e.g. an unterminated quote) makes NimbleCSV raise
    # NimbleCSV.ParseError. Both mean "no usable rows", not a dead LiveView.
    if String.valid?(content) do
      try do
        do_parse_csv(content)
      rescue
        NimbleCSV.ParseError -> []
      end
    else
      []
    end
  end

  defp do_parse_csv(content) do
    case content |> strip_bom() |> NimbleCSV.RFC4180.parse_string(skip_headers: false) do
      [] ->
        []

      [header | data_rows] ->
        index = header_index(header)

        data_rows
        |> Enum.with_index(2)
        |> Enum.map(fn {row, line} -> {line, row_to_attrs(row, index)} end)
    end
  end

  defp header_index(header) do
    header
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {col, idx}, acc ->
      key = col |> to_string() |> String.trim() |> String.downcase()
      if key in @csv_columns, do: Map.put(acc, key, idx), else: acc
    end)
  end

  defp row_to_attrs(row, index) do
    %{
      "email" => fetch_cell(row, index, "email"),
      "name" => fetch_cell(row, index, "name"),
      "company" => fetch_cell(row, index, "company"),
      "locale" => fetch_cell(row, index, "locale")
    }
  end

  defp fetch_cell(row, index, key) do
    case Map.get(index, key) do
      nil -> nil
      idx -> row |> Enum.at(idx) |> blank_to_nil()
    end
  end

  defp parse_text(content) do
    if String.valid?(content) do
      content
      |> strip_bom()
      |> String.split(~r/\r\n|\r|\n/)
      |> Enum.with_index(1)
      |> Enum.reduce([], &text_row/2)
      |> Enum.reverse()
    else
      []
    end
  end

  defp text_row({raw_line, line}, acc) do
    case blank_to_nil(raw_line) do
      nil ->
        acc

      email ->
        [{line, %{"email" => email, "name" => nil, "company" => nil, "locale" => nil}} | acc]
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # ── Row pipeline ────────────────────────────────────────────────────
  #
  # `run/3` (writes) and `preview_rows/2` (read-only) share this entire
  # pipeline — only the last step (the `resolver` fun) differs between them,
  # so the no_email/invalid_email/duplicate_in_file classification and the
  # accumulator threading can never drift between what a preview promises
  # and what the real run does.

  defp run(parsed_rows, %ContactList{} = list, opts) do
    members_by_email = Lists.members_by_email(list, distinct_emails(parsed_rows))

    {report, _seen} =
      process_all(parsed_rows, list, fn attrs, email ->
        import_row(attrs, email, list, opts, members_by_email)
      end)

    finalize_report(report)
  end

  defp process_all(parsed_rows, list, resolver),
    do: process_all(parsed_rows, list, resolver, new_accumulator())

  defp process_all(parsed_rows, list, resolver, {report, seen}) do
    Enum.reduce(parsed_rows, {report, seen}, fn {line, attrs}, {report, seen} ->
      process_row(line, attrs, list, report, seen, resolver)
    end)
  end

  defp process_row(line, attrs, list, report, seen, resolver) do
    case attrs["email"] do
      nil ->
        {skip(report, line, nil, :no_email), seen}

      raw_email ->
        email = normalize_email(raw_email)

        cond do
          not Contact.valid_email?(email) ->
            {skip(report, line, email, :invalid_email), seen}

          MapSet.member?(seen, email) ->
            {skip(report, line, email, :duplicate_in_file), seen}

          true ->
            result = resolver.(attrs, email)
            {apply_result(report, line, email, result, list), MapSet.put(seen, email)}
        end
    end
  end

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()

  # Checks the chunk's pre-fetched members_by_email map before ever
  # attempting a write: a KNOWN collision (already imported, or a prior
  # membership still holding the email slot) is classified straight from
  # the map, matching preview_row/2's return shape exactly — apply_result/5
  # already has clauses for both. Re-importing a large duplicate file used
  # to pay a contact INSERT + transaction rollback for every single
  # colliding row; this reuses the same batched lookup preview_rows/2 uses
  # to skip the write outright for anything the map already knows about.
  # Only a genuinely unknown email reaches do_import_row/4's transactional
  # insert — a race against a concurrent import between the batched lookup
  # and the insert is still caught there by the DB's own unique index.
  defp import_row(attrs, email, list, opts, members_by_email) do
    case Map.get(members_by_email, email) do
      %{status: "removed"} -> {:error, :unsubscribed}
      %{} -> {:error, :already_in_list}
      nil -> do_import_row(attrs, email, list, opts)
    end
  end

  defp do_import_row(attrs, email, list, opts) do
    contact_attrs = %{
      "name" => attrs["name"] || email,
      "email" => email,
      "locale" => valid_locale_or_nil(attrs["locale"]),
      "metadata" => import_metadata(attrs)
    }

    Lists.add_new_contact_to_list(contact_attrs, list, Keyword.put(opts, :source, "import"))
  end

  # Read-only counterpart to import_row/4, classifying against the ONE
  # batched lookup preview_rows/2 already ran rather than querying per row.
  # Classifies removed-vs-active directly here (unlike the real write path,
  # which only learns about a collision from a DB constraint error and has
  # to look the row up separately to classify it — see apply_result/5).
  defp preview_row(email, members_by_email) do
    case Map.get(members_by_email, email) do
      nil -> {:ok, :would_import}
      %{status: "removed"} -> {:error, :unsubscribed}
      %{} -> {:error, :already_in_list}
    end
  end

  defp import_metadata(attrs) do
    %{"source" => "import"} |> maybe_put("import_company", attrs["company"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp valid_locale_or_nil(nil), do: nil

  defp valid_locale_or_nil(locale) do
    if Regex.match?(@locale_format, locale), do: locale, else: nil
  end

  defp apply_result(report, line, email, {:ok, _}, _list) do
    report
    |> Map.update!(:created, &(&1 + 1))
    |> Map.update!(:added, &(&1 + 1))
    |> add_row(line, email, :imported, nil)
  end

  defp apply_result(report, line, email, {:error, :email_already_in_list}, list) do
    reason =
      case Lists.get_member_by_email(list, email) do
        %{status: "removed"} -> :unsubscribed
        _ -> :already_in_list
      end

    skip(report, line, email, reason)
  end

  # preview_row/2 already did the removed-vs-active classification itself
  # (against the batched lookup), so these two just skip directly — no
  # extra per-row query the way the {:email_already_in_list} clause above
  # needs for the real write path.
  defp apply_result(report, line, email, {:error, :unsubscribed}, _list) do
    skip(report, line, email, :unsubscribed)
  end

  defp apply_result(report, line, email, {:error, :already_in_list}, _list) do
    skip(report, line, email, :already_in_list)
  end

  defp apply_result(report, line, email, {:error, :already_member}, _list) do
    # Structurally unreachable — the imported contact is always brand-new,
    # so it can never already be a member of this list. Kept only so this
    # stays exhaustive against add_new_contact_to_list/3's real return type.
    skip(report, line, email, :already_in_list)
  end

  defp apply_result(report, line, email, {:error, %Ecto.Changeset{} = changeset}, _list) do
    # No email in the log line — rejected-row emails are PII; the line
    # number is enough to find the row in the source file.
    Logger.warning("[CRM] Import row #{line} rejected: #{inspect(changeset.errors)}")

    skip(report, line, email, :invalid_email)
  end

  defp skip(report, line, email, reason) do
    report
    |> Map.update!(:skipped, &Map.update!(&1, reason, fn n -> n + 1 end))
    |> add_row(line, email, :skipped, reason)
  end

  # Prepends (newest-first) — appending would copy the whole accumulator
  # per row, which is O(n²) on a file near the upload size limit. Order is
  # restored by finalize_report/1 when the run/preview completes.
  defp add_row(report, line, email, outcome, reason) do
    Map.update!(
      report,
      :rows,
      &[%{line: line, email: email, outcome: outcome, reason: reason} | &1]
    )
  end
end
