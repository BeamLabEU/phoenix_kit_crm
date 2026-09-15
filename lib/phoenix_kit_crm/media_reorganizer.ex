defmodule PhoenixKitCRM.MediaReorganizer do
  @moduledoc """
  CRM's media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core (2.23.x) does not ship the engine yet. This
  module declares no `@behaviour` and returns plain maps; see
  `PhoenixKitCRM.media_reorganizer/0` for the registration comment. Once core
  ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts) :: [map()]`)
  already matches `Source.plan/2` — the only follow-up is adding
  `@behaviour`/`@impl`.

  Covers contacts, companies and interactions (their own attachment root
  folders) and orphaned legacy folders whose record is missing, trashed, or
  (interactions only) whose anchor contact/company is trashed.

  Two things every other Source in this rollout has that CRM does not:

    * **No pointer.** Contact/Company/Interaction cache nothing — a folder is
      resolved by its deterministic name every time (see
      `PhoenixKitCRM.Attachments` moduledoc). `after_move` is therefore
      always `nil`.
    * **No pending-upload folders.** CRM never stages an upload before the
      owning record exists, so there is no `crm-attachment-pending-*` prefix
      and no `:pending` action kind here.

  A host that has not configured `:attachments_parent_folder` is left
  entirely untouched — no resource actions at all, and the parent hook is
  never called (D1). When it IS configured, the hook is only ever called for
  a record that already has a *candidate* folder — a live folder anywhere
  named after its legacy deterministic name (checked without calling the
  hook, one batched query for the whole plan) — never for a record with
  nothing to move (X12).

  ## Current-folder resolution

  For a candidate record, the current folder is looked up **only** at the
  storage root or under the hook-resolved parent (the module's own lookup
  order, `Attachments.get_folder/2`) — never "anywhere" in the tree (X9): a
  folder the owner moved out of root/parent to some unrelated place is left
  alone and reported (`kind: :relocated`), never silently moved back or
  adopted from wherever it now lives. A legacy name live in **both** root and
  the resolved parent is likewise unresolvable — reported as one
  `kind: :duplicate` action naming both folders, nothing moved. Two (or more)
  records sharing the very same live folder get one `kind: :duplicate` report
  each, no move for any of them.

  `on_conflict: :report` (D3, not `:suffix`) — CRM writes no pointer, so a
  folder the engine renamed to dodge a collision ("Name (2)") would become
  invisible to the module's own by-exact-name lookup and effectively
  orphaned; a human decides instead.

  A moved root folder's nested `Images` subfolder needs no action of its
  own — its `parent_uuid` already points at the root folder's uuid, which
  the move leaves unchanged, so it travels with its parent for free.

  ## Interactions of a trashed contact/company

  An interaction's anchor (its contact or company) is immutable, but the
  anchor itself can be trashed after the interaction was logged. Such an
  interaction is skipped entirely by the move-planning pass above (no hook
  call, no move) and, if it has a legacy folder, that folder is reported as
  an orphan instead (D8) — same shape as any other orphan report, naming
  which anchor is trashed.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitCRM.Attachments
  alias PhoenixKitCRM.Schemas.{Company, Contact, Interaction}

  @source "crm"
  @legacy_prefix "crm-"

  @legacy_kinds [
    {"crm-interaction-", :interaction},
    {"crm-company-", :company},
    {"crm-contact-", :contact}
  ]

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds the CRM's reorganizer plan: one `:move` action per contact, company
  and (anchor-live) interaction whose current folder does not already match
  the host's `:attachments_parent_folder` hook, `:report` (`kind:
  :duplicate`) for folders that cannot be unambiguously resolved, `:report`
  (`kind: :relocated`) for a legacy folder the owner moved elsewhere, and
  `:report` (`kind: :orphan`) per legacy folder whose record is missing,
  trashed, or (interactions) anchored to a trashed contact/company.

  `opts` is accepted for parity with the `Source.plan/2` contract but unused
  — CRM has no pending-folder concept (see moduledoc).
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    {resource_actions, resolved_parents} = resource_plan(actor_uuid)

    resource_actions ++
      trashed_anchor_orphan_actions() ++
      orphan_actions(resolved_parents)
  end

  # ── Contacts / companies / interactions ─────────────────────────

  # D1: a host without the parent hook configured is left entirely untouched
  # — no candidate detection, no hook call, no move/duplicate/relocated
  # action. Orphan detection (below) is independent housekeeping and still
  # runs (root is always in scope).
  defp resource_plan(actor_uuid) do
    if hook_configured?() do
      tagged_records =
        tag(live_contacts(), :contact) ++
          tag(live_companies(), :company) ++
          tag(live_interactions(), :interaction)

      {actions, resolved_parents} = build_resource_plan(tagged_records, actor_uuid)

      # X13: one extra hook call per kind (no subject) so a legacy folder
      # under a kind's parent is still found by orphan detection even when
      # that kind currently has zero live/candidate records.
      {actions, Enum.uniq(resolved_parents ++ kind_default_parents(actor_uuid))}
    else
      {[], []}
    end
  end

  defp hook_configured? do
    match?(
      {mod, fun} when is_atom(mod) and is_atom(fun),
      Application.get_env(:phoenix_kit_crm, :attachments_parent_folder)
    )
  end

  defp kind_default_parents(actor_uuid) do
    [:contact, :company, :interaction]
    |> Enum.map(&Attachments.parent_folder_uuid(&1, actor_uuid, nil))
    |> Enum.reject(&is_nil/1)
  end

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  # Candidate detection needs no hook call: a live folder anywhere named
  # after the record's legacy name. Only candidates go on to have the host's
  # parent hook resolved — a record with nothing pointing at it never
  # triggers a (possibly writing) host hook (X12).
  defp build_resource_plan(tagged_records, actor_uuid) do
    prelim =
      Enum.map(tagged_records, fn {record, kind} ->
        %{record: record, kind: kind, legacy_name: legacy_name(kind, record)}
      end)

    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    candidates = Enum.filter(prelim, &Map.has_key?(by_name, &1.legacy_name))

    desired =
      Enum.map(candidates, fn p ->
        Map.put(
          p,
          :parent_uuid,
          Attachments.parent_folder_uuid(p.kind, actor_uuid, p.record.uuid)
        )
      end)

    entries = Enum.map(desired, &resolve_entry(&1, by_name))

    resolved_parents =
      desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {unique, ambiguous_dup, shared_dup, relocated} = classify_entries(entries)

    move_actions = unique |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous_dup, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared_dup, &build_shared_duplicate_action/1)
    relocated_actions = Enum.map(relocated, &build_relocated_action/1)

    all_actions = move_actions ++ dup_actions ++ shared_actions ++ relocated_actions

    {finalize_counts(all_actions), resolved_parents}
  end

  defp legacy_name(:interaction, record), do: Attachments.interaction_folder_name(record.uuid)
  defp legacy_name(kind, record), do: Attachments.root_folder_name(kind, record.uuid)

  # Resolves one record's current folder — root or the resolved parent ONLY
  # (module's own order — never "anywhere", X9). A live match at both is
  # ambiguous (X11). A live match somewhere else entirely (the owner moved
  # it) resolves to neither — reported `:relocated` by the caller, never
  # moved back or adopted from where it now lives.
  defp resolve_entry(d, by_name) do
    matches = Map.get(by_name, d.legacy_name, [])
    under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

    case {under_parent, at_root} do
      {nil, nil} ->
        Map.merge(d, %{folder: nil, ambiguous: nil, elsewhere: matches})

      {same, same} ->
        Map.merge(d, %{folder: same, ambiguous: nil, elsewhere: nil})

      {f, nil} ->
        Map.merge(d, %{folder: f, ambiguous: nil, elsewhere: nil})

      {nil, f} ->
        Map.merge(d, %{folder: f, ambiguous: nil, elsewhere: nil})

      {f1, f2} ->
        Map.merge(d, %{folder: nil, ambiguous: {f1, f2}, elsewhere: nil})
    end
  end

  # Splits resolved entries into: `unique` (one record ↔ one folder, safe to
  # plan a move for), `ambiguous_dup` (legacy name live at both root and
  # under the resolved parent — X11), `shared_dup` (two or more records
  # resolving to the very same live folder — X5), `relocated` (a live match
  # exists only outside root/the resolved parent — X9).
  defp classify_entries(entries) do
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {relocated, normal} = Enum.split_with(normal, &(is_nil(&1.folder) and &1.elsewhere != []))
    {with_folder, _without_folder} = Enum.split_with(normal, & &1.folder)

    grouped = Enum.group_by(with_folder, & &1.folder.uuid)

    {shared, unique} =
      Enum.reduce(grouped, {[], []}, fn {_uuid, group}, {shared_acc, unique_acc} ->
        if length(group) > 1 do
          {[group | shared_acc], unique_acc}
        else
          {shared_acc, group ++ unique_acc}
        end
      end)

    {unique, ambiguous, shared, relocated}
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` is a
  # no-op — filtered here since this Source has no core `Action.noop?/1` to
  # lean on, and (unlike catalogue) there is never an `after_move` to keep
  # the action alive for.
  defp build_move_action(entry) do
    %{record: record, kind: kind, folder: folder, parent_uuid: parent_uuid, legacy_name: name} =
      entry

    if noop_move?(folder, parent_uuid, name) do
      nil
    else
      %{
        source: @source,
        kind: kind,
        label: record_label(record),
        op: :move,
        folder: folder,
        parent_uuid: parent_uuid,
        name: name,
        counts: nil,
        on_conflict: :report,
        after_move: nil
      }
    end
  end

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true
  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp build_ambiguous_duplicate_action(%{record: record, kind: kind, ambiguous: {f1, f2}}) do
    %{
      source: @source,
      kind: :duplicate,
      label: record_label(record),
      op: :report,
      counts: nil,
      reason:
        "legacy #{kind} folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
    }
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(&record_label(&1.record)) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: @source,
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one record: #{labels}"
    }
  end

  defp build_relocated_action(%{record: record, kind: kind, elsewhere: folders}) do
    locations = Enum.map_join(folders, ", ", & &1.uuid)

    %{
      source: @source,
      kind: :relocated,
      label: record_label(record),
      op: :report,
      counts: nil,
      reason:
        "legacy #{kind} folder is live at #{locations} — outside root and the resolved parent, left alone"
    }
  end

  defp record_label(%Contact{} = c), do: c.name
  defp record_label(%Company{} = c), do: c.name
  defp record_label(%Interaction{} = i), do: i.subject || i.uuid

  # One query for every distinct legacy name in the batch, live folders only
  # (X2 — the unique index is partial, a trashed twin must not hide the live
  # folder), matching ANYWHERE — used only to decide candidacy (X12) and to
  # detect a relocated folder (X9); `resolve_entry/2` still restricts the
  # actual move target to root/parent.
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  defp live_contacts do
    Contact |> where([c], c.status != "trashed") |> repo().all()
  end

  defp live_companies do
    Company |> where([c], c.status != "trashed") |> repo().all()
  end

  # Interaction has no soft-delete field of its own — an interaction is live
  # for move-planning unless its anchor (contact or company) is trashed
  # (D8); those are handled separately by `trashed_anchor_orphan_actions/0`.
  defp live_interactions do
    Interaction
    |> join(:left, [i], c in Contact, on: i.contact_uuid == c.uuid)
    |> join(:left, [i, _c], co in Company, on: i.company_uuid == co.uuid)
    |> where(
      [i, c, co],
      (is_nil(i.contact_uuid) or c.status != "trashed") and
        (is_nil(i.company_uuid) or co.status != "trashed")
    )
    |> select([i], i)
    |> repo().all()
  end

  # ── Interactions anchored to a trashed contact/company (D8) ─────

  # Such an interaction is skipped by move-planning above (never in
  # `live_interactions/0`, so the parent hook is never called for it — same
  # "skip the hook" spirit as X12). If it has a legacy folder, it is
  # reported as an orphan instead — searched anywhere by name (not just
  # root/the resolved parent — the hook was never run for it, so there is no
  # "resolved parent" to restrict to).
  defp trashed_anchor_orphan_actions do
    interactions = trashed_anchor_interactions()

    if interactions == [] do
      []
    else
      names =
        Enum.map(interactions, fn {i, _reason} -> Attachments.interaction_folder_name(i.uuid) end)

      by_name = preload_by_name_anywhere(names)

      interactions
      |> Enum.flat_map(&trashed_anchor_orphan_folders(&1, by_name))
      |> finalize_counts()
    end
  end

  defp trashed_anchor_interactions do
    contact_trashed =
      Interaction
      |> join(:inner, [i], c in Contact, on: i.contact_uuid == c.uuid and c.status == "trashed")
      |> select([i], i)
      |> repo().all()
      |> Enum.map(&{&1, "contact"})

    company_trashed =
      Interaction
      |> join(:inner, [i], co in Company,
        on: i.company_uuid == co.uuid and co.status == "trashed"
      )
      |> select([i], i)
      |> repo().all()
      |> Enum.map(&{&1, "company"})

    contact_trashed ++ company_trashed
  end

  defp trashed_anchor_orphan_folders({interaction, anchor_kind}, by_name) do
    name = Attachments.interaction_folder_name(interaction.uuid)

    by_name
    |> Map.get(name, [])
    |> Enum.map(fn folder ->
      %{
        source: @source,
        kind: :orphan,
        op: :report,
        label: record_label(interaction),
        folder: folder,
        counts: nil,
        reason: "interaction's anchor #{anchor_kind} is trashed"
      }
    end)
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`crm-contact-<uuid>`, `crm-company-<uuid>`,
  # `crm-interaction-<uuid>`) at the media root or under a parent this
  # batch's hooks resolved to, whose uuid no longer names a live record
  # (missing, or the record exists but was soft-deleted — Contact/Company
  # only; a found `Interaction` row is always live here, its trashed-anchor
  # twin having already been filtered into `trashed_anchor_orphan_actions/0`
  # above) is reported so a host can collect it. Never `:move`d or
  # `:trash`ed here — this module owns no "orphans" container; a legacy
  # folder that IS a live record's current folder is left to
  # `build_move_action/1` above.
  defp orphan_actions(resolved_parents) do
    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _kind} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the CRM legacy prefix. Live only (X2).
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind(&1.name)})
    |> Enum.filter(fn {_folder, kind} -> kind end)
  end

  defp legacy_kind(name), do: Enum.find_value(@legacy_kinds, &legacy_kind_match(name, &1))

  # X7: a strict UUID regex on the suffix (36-char canonical form) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and would key
  # the map differently than the record's (lowercased) uuid.
  defp legacy_kind_match(name, {prefix, kind}) do
    if String.starts_with?(name, prefix) do
      suffix = String.replace_prefix(name, prefix, "")

      if Regex.match?(@uuid_regex, suffix) do
        {kind, String.downcase(suffix)}
      end
    end
  end

  # One query per record kind present among the candidates — not per folder.
  defp load_candidate_records(candidates) do
    by_kind =
      Enum.group_by(
        candidates,
        fn {_folder, {kind, _uuid}} -> kind end,
        fn {_folder, {_kind, uuid}} -> uuid end
      )

    %{}
    |> Map.merge(load_records(Contact, :contact, Map.get(by_kind, :contact, [])))
    |> Map.merge(load_records(Company, :company, Map.get(by_kind, :company, [])))
    |> Map.merge(load_records(Interaction, :interaction, Map.get(by_kind, :interaction, [])))
  end

  defp load_records(_schema, _kind, []), do: %{}

  defp load_records(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> repo().all()
    |> Map.new(&{{kind, &1.uuid}, &1})
  end

  defp orphan_action({folder, {kind, uuid}}, records_by_key, counts) do
    record = Map.get(records_by_key, {kind, uuid})

    if orphan?(record) do
      folder_counts = folder_counts(counts, folder.uuid)

      %{
        source: @source,
        kind: :orphan,
        op: :report,
        label: folder.name,
        folder: folder,
        counts: folder_counts,
        reason: orphan_reason(record, folder_counts)
      }
    end
  end

  # No record at all → orphan. A found `Interaction` row is always live here
  # (its trashed-anchor case never reaches this path, see
  # `live_interactions/0` above). Contact/Company use the shared "trashed"
  # sentinel.
  defp orphan?(nil), do: true
  defp orphan?(%Interaction{}), do: false
  defp orphan?(%{status: "trashed"}), do: true
  defp orphan?(_), do: false

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%{status: status}, {files, _links}),
    do: "record status #{status}, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid) for
  # the whole plan's folder set — never a query per action. Counts ALL rows
  # regardless of status (including trashed files) — the core engine
  # re-measures the same way at apply time (any row with this folder_uuid)
  # and aborts the action on a mismatch, so a plan-time count that excluded
  # trashed files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders with a single batched lookup across
  # every action's folder — the whole batch's folder counts come from one
  # pair of grouped queries (X1), not one pair per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
