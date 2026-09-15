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

  `plan/2` derives the desired parent from the exact hook
  (`Attachments.parent_folder_uuid/3`) a fresh folder resolution uses, so a
  plan describes exactly what the module would do today. Once every folder
  already sits where its plan says, the action is filtered out — a second
  run plans nothing.

  Covers contacts, companies and interactions (their own attachment root
  folders) and orphaned legacy folders whose record is missing or trashed
  (reported, never moved/trashed — see "Orphaned legacy folders" below).

  Two things every other Source in this rollout has that CRM does not:

    * **No pointer.** Contact/Company/Interaction cache nothing — a folder is
      resolved by its deterministic name every time (see
      `PhoenixKitCRM.Attachments` moduledoc). `after_move` is therefore
      always `nil`; there is nothing to back-fill.
    * **No pending-upload folders.** CRM never stages an upload before the
      owning record exists, so there is no `crm-attachment-pending-*`
      prefix and no `:pending` action kind here.

  ## Current-folder resolution

  `PhoenixKitCRM.Attachments.get_folder/2` (private) picks, among every live
  folder sharing a record's deterministic name anywhere in the tree, the one
  under the resolved parent first, else the one at root, else the oldest —
  never adopting, never twinning. `plan/2` replicates that exact priority
  (`current_folder/2` below) instead of calling the private function, so the
  whole batch resolves in one query per distinct legacy name rather than one
  round trip per record.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitCRM.Attachments
  alias PhoenixKitCRM.Schemas.{Company, Contact, Interaction}

  @source "crm"

  @doc """
  Builds the CRM's reorganizer plan: one `:move` action per contact, company
  and interaction whose current folder does not already match the host's
  `:attachments_parent_folder` hook, plus a `:report` (`kind: :orphan`) per
  legacy folder whose record is missing or trashed.

  `opts` is accepted for parity with the `Source.plan/2` contract but unused
  — CRM has no pending-folder concept (see moduledoc).
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    tagged_records =
      tag(live_contacts(), :contact) ++
        tag(live_companies(), :company) ++
        tag(live_interactions(), :interaction)

    # Desired parent (the host hook, possibly a DB lookup) is resolved
    # exactly once per record here and threaded into both passes below —
    # `orphan_actions/1` reuses `desired`'s `parent_uuid`s instead of
    # re-running the hook.
    desired = resolve_desired(tagged_records, actor_uuid)

    resource_actions(desired) ++ orphan_actions(desired)
  end

  # ── Contacts / companies / interactions ─────────────────────────

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  defp resolve_desired(tagged_records, actor_uuid) do
    Enum.map(tagged_records, fn {record, kind} ->
      %{
        record: record,
        kind: kind,
        parent_uuid: Attachments.parent_folder_uuid(kind, actor_uuid, record.uuid),
        legacy_name: legacy_name(kind, record)
      }
    end)
  end

  defp legacy_name(:interaction, record), do: Attachments.interaction_folder_name(record.uuid)
  defp legacy_name(kind, record), do: Attachments.root_folder_name(kind, record.uuid)

  # Every folder lookup for the whole batch runs as one preloaded query (by
  # legacy name, live folders only) instead of one round trip per record.
  defp resource_actions(desired) do
    by_name = preload_by_name(Enum.map(desired, & &1.legacy_name))

    desired
    |> Enum.map(&resource_action(&1, by_name))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(desired, by_name) do
    %{record: record, kind: kind, parent_uuid: parent_uuid, legacy_name: name} = desired

    case current_folder(desired, by_name) do
      nil ->
        nil

      %Folder{} = folder ->
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
            counts: counts(folder.uuid),
            on_conflict: :suffix,
            # No pointer anywhere on Contact/Company/Interaction — nothing to
            # back-fill after the move (see moduledoc).
            after_move: nil
          }
        end
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` is a
  # no-op — filtered here since this Source has no core `Action.noop?/1` to
  # lean on, and (unlike catalogue) there is never an `after_move` to keep
  # the action alive for.
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true
  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp record_label(%Contact{} = c), do: c.name
  defp record_label(%Company{} = c), do: c.name
  defp record_label(%Interaction{} = i), do: i.subject || i.uuid

  # One query for every distinct legacy name in the batch, live folders only,
  # regardless of where they currently live (mirrors `Attachments.get_folder/2`
  # searching "anywhere", not just root/parent).
  defp preload_by_name(names) do
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

  # The live folder matching the record's legacy name, picked with the exact
  # priority `Attachments.get_folder/2`'s `prefer_parent/2` uses: under the
  # resolved parent first, then at root, then the oldest anywhere else. `nil`
  # when no live folder has this name — nothing to move (the module creates
  # one lazily on first upload).
  defp current_folder(%{legacy_name: name, parent_uuid: parent_uuid}, by_name) do
    case Map.get(by_name, name) do
      nil -> nil
      folders -> Enum.min_by(folders, &sort_key(&1, parent_uuid))
    end
  end

  defp sort_key(%Folder{parent_uuid: p, inserted_at: ts}, target) do
    {parent_match_rank(p, target), root_rank(p), DateTime.to_unix(ts, :microsecond)}
  end

  defp parent_match_rank(p, target) when not is_nil(target) and p == target, do: 0
  defp parent_match_rank(_p, _target), do: 1

  defp root_rank(nil), do: 0
  defp root_rank(_), do: 1

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`crm-contact-<uuid>`, `crm-company-<uuid>`,
  # `crm-interaction-<uuid>`) at the media root or under a parent this
  # batch's hook resolved to, whose uuid no longer names a live record
  # (missing, or the record exists but was soft-deleted — Contact/Company
  # only; Interaction has no soft-delete, a row that exists is always live)
  # is reported so a host can collect it. Never `:move`d or `:trash`ed here
  # — this module owns no "orphans" container; a legacy folder that IS a
  # live record's current folder is left to `resource_action/2` above.
  # Reuses `desired`'s `parent_uuid`s (already resolved once per record in
  # `plan/2`) rather than calling the host hook again.
  defp orphan_actions(desired) do
    resolved_parents =
      desired
      |> Enum.map(& &1.parent_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One query for every legacy-named folder at root or under a resolved
  # parent — not a query per folder.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind(&1.name)})
    |> Enum.filter(fn {_folder, kind} -> kind end)
  end

  @legacy_kinds [
    {"crm-interaction-", :interaction},
    {"crm-company-", :company},
    {"crm-contact-", :contact}
  ]

  defp legacy_kind(name), do: Enum.find_value(@legacy_kinds, &legacy_kind_match(name, &1))

  defp legacy_kind_match(name, {prefix, kind}) do
    with true <- String.starts_with?(name, prefix),
         uuid <- String.replace_prefix(name, prefix, ""),
         {:ok, _} <- Ecto.UUID.cast(uuid) do
      {kind, uuid}
    else
      _ -> nil
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

  defp orphan_action({folder, {kind, uuid}}, records_by_key) do
    record = Map.get(records_by_key, {kind, uuid})

    if orphan?(record) do
      counts = counts(folder.uuid)

      %{
        source: @source,
        kind: :orphan,
        op: :report,
        label: folder.name,
        folder: folder,
        counts: counts,
        reason: orphan_reason(record, counts)
      }
    end
  end

  # No record at all → orphan. An `Interaction` never has a "deleted" status
  # (hard-deleted, and `delete_interaction/2` purges its folder itself) — a
  # found interaction row is always live. Contact/Company use the shared
  # "trashed" sentinel.
  defp orphan?(nil), do: true
  defp orphan?(%Interaction{}), do: false
  defp orphan?(%{status: "trashed"}), do: true
  defp orphan?(_), do: false

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%{status: status}, {files, _links}),
    do: "record status #{status}, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # Counts ALL rows regardless of status (including trashed files) — the
  # core engine re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time count
  # that excluded trashed files would fail every folder holding one.
  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    links =
      FolderLink
      |> where([l], l.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    {files, links}
  end

  defp live_contacts do
    Contact |> where([c], c.status != "trashed") |> repo().all()
  end

  defp live_companies do
    Company |> where([c], c.status != "trashed") |> repo().all()
  end

  # Interaction has no soft-delete field — every row is live (a deleted
  # interaction is hard-deleted, see `Interactions.delete_interaction/2`).
  defp live_interactions do
    repo().all(Interaction)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
