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
  nothing to move (X12), and never without a subject (R8): a legacy folder
  under a parent no live candidate of a kind ever resolved simply stays
  outside this plan's reach, rather than the module forcing one extra hook
  call per kind on every run to widen that reach. The orphan scan's scope is
  root plus every parent a hook call actually returned for some candidate,
  regardless of that candidate's own outcome — moved, relocated, duplicate,
  or `:hook_nil` all count (U4/V2); a parent an F1-adopted folder merely
  happens to already sit under, without the hook ever having returned it,
  never widens that scope.

  A configured hook that raises, exits, or returns anything but `{:ok, uuid}`
  or an explicit `nil` is a hook FAILURE (R2): that one record is skipped —
  no move, no relocated report — and counted into a single `kind:
  :hook_error` report for the whole plan, naming (up to 10, then "… and N
  more") every skipped record's label (U8). Only an explicit `nil` means
  root. A configured value that is not a `{mod, fun}` pair naming an
  exported function — a typo, a removed function, or outright garbage (a
  string, an atom, a stray tuple) — is one and the same distinct failure
  (T3/U7/V3): it is never treated as "no hook configured" (that state is
  reserved for the key being entirely absent), the hook is not called for
  any candidate, and the plan reports one `kind: :hook_error` naming the
  invalid config. Every `{:ok, uuid}` answer is cast through
  `Ecto.UUID.cast/1` before it is used anywhere (T1): a syntactically
  invalid uuid is a hook FAILURE too, never a `CastError` further down the
  plan, and the cast also normalizes case, so an upper-case answer still
  matches the (lower-case) `parent_uuid` stored on `Folder`. Every hook
  call site — an exception, or a return value that is neither `{:ok, uuid}`
  nor `nil` — logs a warning naming the `{mod, fun}` and the record kind
  (U6/T4), not only exceptions.

  ## Current-folder resolution

  For a candidate record, the current folder is looked up **only** at the
  storage root or under the hook-resolved parent (the module's own lookup
  order — one batched query loads every live folder sharing the legacy name,
  `preload_by_name_anywhere/1`, then `resolve_entry/3` picks whichever copy
  sits at root or the resolved parent) — never "anywhere" in the tree (X9): a
  folder the owner moved out of root/parent to some unrelated place is left
  alone and reported (`kind: :relocated` — the reason names it as
  actor-dependent, since CRM's hook can resolve differently per acting user,
  E6). Only when the legacy name is live at **both** root and the resolved
  parent at once is the record unresolvable: one `kind: :duplicate` report
  names every live copy, nothing moves (R7). When exactly one live copy
  sits at a valid location (root or the resolved parent), that copy IS the
  current folder — every other live copy of the same legacy name, wherever
  it lives, gets its own `kind: :relocated` report (F5: all of them, not
  only the first), its reason naming the actual place — the media root,
  already a twin under the resolved target parent, or by name under a
  genuine third-party parent (U3; the third case batches one lookup of
  every such parent's name for the whole plan). Two different records can
  never converge on the very same folder here, since each record's legacy
  name embeds its own uuid.

  An explicit `nil` hook answer (root) never pulls a folder that is already
  live under a real parent out to root (F1). CRM has no pointer to identify
  the current folder independent of the hook's answer, so this case is
  resolved on its own: when the legacy name is live at exactly one
  location — root or otherwise — that copy unambiguously IS the current
  folder (again, the legacy name embeds the record's own uuid). Its parent
  is left exactly as it is and the record is counted into one aggregated
  `kind: :hook_nil` report instead of a `:relocated` one. The legacy name
  being live in more than one place at once, with no hook answer to
  disambiguate which is current, is unresolvable the same way R7 is — one
  `kind: :duplicate` report naming every live copy.

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

  require Logger

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
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
  (`kind: :relocated`) for a legacy folder the owner moved elsewhere,
  `:report` (`kind: :hook_error`) when the configured hook fails for one or
  more records, `:report` (`kind: :hook_nil`) when an explicit-root hook
  answer is suppressed for one or more records already living under a real
  parent, and `:report` (`kind: :orphan`) per legacy folder whose record is
  missing, trashed, or (interactions) anchored to a trashed contact/company.

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
  # runs (root is always in scope). T3: a configured but uncallable hook is
  # a distinct failure — reported once, without ever building candidates or
  # calling the hook.
  defp resource_plan(actor_uuid) do
    case hook_status() do
      {:ok, mod, fun} ->
        tagged_records =
          tag(light_contacts(), :contact) ++
            tag(light_companies(), :company) ++
            tag(light_interactions(), :interaction)

        build_resource_plan(tagged_records, mod, fun, actor_uuid)

      {:not_callable, config} ->
        {[not_callable_hook_action(config)], []}

      :none ->
        {[], []}
    end
  end

  # U7/V3: any configured value that is not a `{mod, fun}` pair naming an
  # exported function is one and the same failure — a typo'd module, a
  # removed function, and outright garbage (a string, an atom, a 3-tuple)
  # all report `:hook_error` "not callable"; none of them is silently
  # treated as "no hook configured" (that state is reserved for the key
  # being entirely absent — `nil`, F2's root sentinel elsewhere).
  defp hook_status do
    case Application.get_env(:phoenix_kit_crm, :attachments_parent_folder) do
      nil ->
        :none

      {mod, fun} = config when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: {:ok, mod, fun}, else: {:not_callable, config}

      config ->
        {:not_callable, config}
    end
  end

  defp callable?(mod, fun) do
    Code.ensure_loaded?(mod) and
      (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))
  end

  defp not_callable_hook_action(config) do
    %{
      source: @source,
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason: "configured parent hook #{inspect(config)} is not callable (invalid config)"
    }
  end

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  # Candidate detection needs no hook call: a live folder anywhere named
  # after the record's legacy name. Only candidates go on to have the host's
  # parent hook resolved — a record with nothing pointing at it never
  # triggers a (possibly writing) host hook (X12), and never with a nil
  # subject (R8).
  defp build_resource_plan(tagged_records, mod, fun, actor_uuid) do
    prelim =
      Enum.map(tagged_records, fn {record, kind} ->
        %{record: record, kind: kind, legacy_name: legacy_name(kind, record)}
      end)

    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    candidates = Enum.filter(prelim, &Map.has_key?(by_name, &1.legacy_name))

    {resolved, hook_error_labels} = resolve_candidates(candidates, by_name, mod, fun, actor_uuid)

    # U4/V2: orphan scope = root + every parent that came from a SUCCESSFUL
    # hook answer for ANY candidate, regardless of that candidate's outcome
    # (moved, relocated, duplicate, hook_nil) — `hook_parent_uuid` is the
    # raw answer `resolve_parent/5` returned, never the current-folder
    # location `resolve_entry_nil_hook/2` pins an F1-adopted folder to.
    resolved_parents =
      resolved |> Enum.map(& &1.hook_parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    hook_nil_labels =
      resolved |> Enum.filter(& &1.hook_nil) |> Enum.map(&record_label(&1.record))

    {duplicate, normal} = Enum.split_with(resolved, & &1.duplicate)

    move_actions =
      normal
      |> Enum.filter(& &1.folder)
      |> Enum.map(&build_move_action/1)
      |> Enum.reject(&is_nil/1)

    duplicate_actions = Enum.map(duplicate, &build_duplicate_action/1)
    relocated_actions = relocated_actions(normal)
    hook_error_actions = hook_error_action(hook_error_labels)
    hook_nil_actions = hook_nil_action(hook_nil_labels)

    all_actions =
      move_actions ++
        duplicate_actions ++ relocated_actions ++ hook_error_actions ++ hook_nil_actions

    {finalize_counts(all_actions), resolved_parents}
  end

  defp legacy_name(:interaction, record), do: Attachments.interaction_folder_name(record.uuid)
  defp legacy_name(kind, record), do: Attachments.root_folder_name(kind, record.uuid)

  # R2: resolves the desired parent for every candidate via the host's exact
  # hook, distinguishing an explicit `nil` (root) from a hook that
  # raised/exited/returned anything else (failure — the record is skipped,
  # never treated as "root"). `mod`/`fun` are already known callable (T3
  # checked that in `hook_status/0` before this ever runs).
  defp resolve_candidates(candidates, by_name, mod, fun, actor_uuid) do
    {acc, err_labels} =
      Enum.reduce(candidates, {[], []}, fn candidate, {acc, err_labels} ->
        case resolve_parent(mod, fun, candidate.kind, actor_uuid, candidate.record) do
          {:ok, hook_parent_uuid} ->
            entry =
              candidate
              |> resolve_entry(hook_parent_uuid, by_name)
              |> Map.put(:hook_parent_uuid, hook_parent_uuid)

            {[entry | acc], err_labels}

          :error ->
            {acc, [record_label(candidate.record) | err_labels]}
        end
      end)

    {Enum.reverse(acc), Enum.reverse(err_labels)}
  end

  defp resolve_parent(mod, fun, kind, actor_uuid, record) do
    cond do
      function_exported?(mod, fun, 3) ->
        safe_call(mod, fun, kind, fn -> apply(mod, fun, [kind, actor_uuid, record.uuid]) end)

      function_exported?(mod, fun, 2) ->
        safe_call(mod, fun, kind, fn -> apply(mod, fun, [kind, actor_uuid]) end)

      true ->
        :error
    end
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` before it goes
  # anywhere else — `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook FAILURES
  # (`:error`), never forwarded into a later `in ^parent_uuids` query (which
  # would raise a CastError and take down the whole plan). `Ecto.UUID.cast/1`
  # also normalizes case, so an upper-case answer still string-equals the
  # (lower-case) `parent_uuid` stored on `Folder`.
  # U6/T4: every log line — an exception, an unrecognized return value —
  # carries the hook's `{mod, fun}` and the record `kind`, so a failure is
  # traceable to which host callback and which kind of record hit it. A bad
  # RETURN value (`{:error, _}`, `{:ok, "x"}`) is logged too, not only an
  # exception.
  defp safe_call(mod, fun, kind, fun_to_call) do
    case fun_to_call.() do
      {:ok, uuid} when is_binary(uuid) ->
        case valid_uuid(uuid) do
          nil ->
            log_bad_hook_return(mod, fun, kind, {:ok, uuid})
            :error

          cast ->
            {:ok, cast}
        end

      {:ok, nil} ->
        {:ok, nil}

      nil ->
        {:ok, nil}

      other ->
        log_bad_hook_return(mod, fun, kind, other)
        :error
    end
  rescue
    error ->
      Logger.warning(
        "CRM attachments parent hook #{inspect(mod)}.#{fun} (kind=#{kind}) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    err_kind, reason ->
      Logger.warning(
        "CRM attachments parent hook #{inspect(mod)}.#{fun} (kind=#{kind}) #{err_kind}: " <>
          inspect(reason)
      )

      :error
  end

  defp log_bad_hook_return(mod, fun, kind, value) do
    Logger.warning(
      "CRM attachments parent hook #{inspect(mod)}.#{fun} (kind=#{kind}) returned " <>
        "#{inspect(value)} — treated as a hook failure"
    )
  end

  # Returns the CAST/downcased value — not the raw string — so an
  # upper-case hook answer still matches the (lower-case) `parent_uuid`
  # stored on `Folder`. Not a well-formed UUID → `nil`, never sent into an
  # `in ^parent_uuids` query (which would raise a CastError).
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
      :error -> nil
    end
  end

  # Resolves one record's current folder among every live copy of its
  # legacy name. A non-nil hook answer keeps the module's own lookup order
  # (root or the resolved parent ONLY, never "anywhere", X9) — see
  # `resolve_entry_with_parent/3`. An explicit `nil` answer (root) is
  # handled separately (F1) — see `resolve_entry_nil_hook/2` — since CRM has
  # no pointer to identify the current folder independent of the hook's
  # answer (unlike catalogue).
  defp resolve_entry(d, nil, by_name) do
    resolve_entry_nil_hook(d, Map.get(by_name, d.legacy_name, []))
  end

  defp resolve_entry(d, parent_uuid, by_name) do
    resolve_entry_with_parent(d, parent_uuid, Map.get(by_name, d.legacy_name, []))
  end

  # The legacy name being live at BOTH root and the resolved parent at once
  # is unresolvable — reported as one `:duplicate` naming every live copy
  # (R7/P9). Otherwise, a live copy at exactly one of those two valid spots
  # is the current folder — every OTHER live copy of the same legacy name,
  # current folder included or not, gets its own `:relocated` report (F5:
  # all of them, not only the first).
  defp resolve_entry_with_parent(d, parent_uuid, matches) do
    under_parent = Enum.find(matches, &(&1.parent_uuid == parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

    base = base_entry(d, parent_uuid)

    cond do
      under_parent && at_root && under_parent.uuid != at_root.uuid ->
        Map.merge(base, %{folder: nil, matches: matches, duplicate: true, relocated: []})

      under_parent || at_root ->
        current = under_parent || at_root

        Map.merge(base, %{
          folder: current,
          matches: nil,
          duplicate: false,
          relocated: Enum.reject(matches, &(&1.uuid == current.uuid))
        })

      true ->
        Map.merge(base, %{folder: nil, matches: matches, duplicate: false, relocated: matches})
    end
  end

  # F1: an explicit `nil` hook answer never pulls a folder that is already
  # live under a real parent out to root. CRM has no pointer to identify the
  # current folder independent of the hook's answer (unlike catalogue), so
  # when the legacy name is live at exactly one location — root or
  # otherwise — that copy unambiguously IS the current folder: each
  # record's legacy name embeds its own uuid, so no other record could be
  # confused with it. Its `parent_uuid` is pinned to wherever it already
  # lives (never moved to root) and, if that is not root, the record is
  # counted into one aggregated `kind: :hook_nil` report (never the
  # per-record `:relocated` path) instead. The legacy name being live in
  # more than one place at once, with no hook answer to disambiguate which
  # is "current", is unresolvable the same way R7 is — one `:duplicate`
  # report naming every live copy.
  defp resolve_entry_nil_hook(d, [only_match]) do
    Map.merge(base_entry(d, only_match.parent_uuid), %{
      folder: only_match,
      matches: nil,
      duplicate: false,
      relocated: [],
      hook_nil: not is_nil(only_match.parent_uuid)
    })
  end

  defp resolve_entry_nil_hook(d, matches) do
    Map.merge(base_entry(d, nil), %{
      folder: nil,
      matches: matches,
      duplicate: true,
      relocated: []
    })
  end

  defp base_entry(d, parent_uuid) do
    %{
      record: d.record,
      kind: d.kind,
      legacy_name: d.legacy_name,
      parent_uuid: parent_uuid,
      hook_nil: false
    }
  end

  # U3/F5: batched over the whole plan so naming a relocated copy's actual
  # third-party parent never costs a query per copy — only parents that are
  # neither root nor the record's own resolved target need a name looked
  # up (those two cases have their own wording, see `relocated_reason/4`).
  defp relocated_actions(normal) do
    pairs = Enum.flat_map(normal, fn entry -> Enum.map(entry.relocated, &{entry, &1}) end)
    parent_names = load_relocated_parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      build_relocated_action(%{
        record: entry.record,
        kind: entry.kind,
        relocated: folder,
        target_parent_uuid: entry.parent_uuid,
        parent_names: parent_names
      })
    end)
  end

  defp load_relocated_parent_names(pairs) do
    uuids =
      pairs
      |> Enum.map(fn {entry, folder} -> other_parent_uuid(folder, entry.parent_uuid) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids)
        |> select([f], {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp other_parent_uuid(%Folder{parent_uuid: nil}, _target_parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, _target_parent_uuid), do: parent_uuid

  # A `:move` whose folder already sits at `parent_uuid` under `name` is a
  # no-op — filtered here before it ever reaches the core engine; unlike
  # catalogue, there is never an `after_move` to keep the action alive for.
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

  defp build_duplicate_action(%{record: record, kind: kind, matches: matches}) do
    locations = Enum.map_join(matches, ", ", & &1.uuid)

    %{
      source: @source,
      kind: :duplicate,
      label: record_label(record),
      op: :report,
      counts: nil,
      reason:
        "legacy #{kind} folder found live in #{length(matches)} place(s) (#{locations}) " <>
          "— pick one and remove the others"
    }
  end

  defp build_relocated_action(%{record: record, kind: kind, relocated: folder} = ctx) do
    reason =
      relocated_reason(
        folder,
        kind,
        Map.get(ctx, :target_parent_uuid),
        Map.get(ctx, :parent_names, %{})
      )

    %{
      source: @source,
      kind: :relocated,
      label: record_label(record),
      op: :report,
      counts: nil,
      reason: reason
    }
  end

  # U3: the reason names the copy's actual place — at the media root,
  # already under the very parent the record's own hook answer resolved
  # (where an eventual move there would collide), or by name under a
  # genuine third-party parent — instead of a blanket "outside root and the
  # resolved parent" that reads the same for all three cases. The first two
  # clauses are unreachable through live data today: `resolve_entry_with_parent/3`
  # reports root+target both occupied as one `:duplicate` (R7) before a
  # `:relocated` copy is ever built, so every reachable relocated copy here
  # is a genuine third-party parent. Kept for parity with the shared
  # reason-naming pattern (catalogue/warehouse) and in case that ordering
  # changes.
  defp relocated_reason(%Folder{parent_uuid: nil, uuid: uuid}, kind, _target, _names) do
    "legacy #{kind} folder #{uuid} is live at the media root — left alone " <>
      "(the parent hook may resolve differently for another user)"
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid, uuid: uuid}, kind, parent_uuid, _names)
       when not is_nil(parent_uuid) do
    "legacy #{kind} folder #{uuid} is already live as a twin under the target parent " <>
      "— left alone (the parent hook may resolve differently for another user)"
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid, uuid: uuid}, kind, _target, names) do
    parent_label = Map.get(names, parent_uuid, parent_uuid)

    "legacy #{kind} folder #{uuid} is live under #{parent_label} — left alone " <>
      "(the parent hook may resolve differently for another user)"
  end

  defp record_label(%Contact{} = c), do: c.name
  defp record_label(%Company{} = c), do: c.name

  defp record_label(%Interaction{subject: subject, uuid: uuid}) when subject in [nil, ""],
    do: uuid

  defp record_label(%Interaction{} = i), do: i.subject

  defp hook_error_action([]), do: []

  defp hook_error_action(labels) do
    [
      %{
        source: @source,
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(labels)} record(s) skipped: the configured parent hook raised, exited, " <>
            "or returned neither {:ok, uuid} nor nil — #{label_list(labels)}"
      }
    ]
  end

  # F1: an aggregated report, not one per record — mirrors
  # `hook_error_action/1`.
  defp hook_nil_action([]), do: []

  defp hook_nil_action(labels) do
    [
      %{
        source: @source,
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(labels)} record(s): the parent hook answered root for a folder living " <>
            "under a parent — left in place (the parent hook may resolve differently for " <>
            "another user) — #{label_list(labels)}"
      }
    ]
  end

  # U8: names up to 10 records so the owner can tell where to look, instead
  # of a bare count.
  @max_listed_labels 10

  defp label_list(labels) do
    {shown, rest} = Enum.split(labels, @max_listed_labels)

    case rest do
      [] -> Enum.join(shown, ", ")
      rest -> Enum.join(shown, ", ") <> ", … and #{length(rest)} more"
    end
  end

  # One query for every distinct legacy name in the batch, live folders only
  # (X2 — the unique index is partial, a trashed twin must not hide the live
  # folder), matching ANYWHERE — used only to decide candidacy (X12) and to
  # detect relocated/duplicate folders (X9/R7); `resolve_entry/3` still
  # restricts the actual move target to root/parent.
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> order_by([f], asc: f.inserted_at, asc: f.uuid)
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # R9/R10: only the columns a plan needs, deterministically ordered
  # (contacts, then companies, then interactions — interactions reference
  # the other two — each by inserted_at/uuid).
  defp light_contacts do
    Contact
    |> where([c], c.status != "trashed")
    |> order_by([c], asc: c.inserted_at, asc: c.uuid)
    |> select([c], struct(c, [:uuid, :name, :status, :inserted_at]))
    |> repo().all()
  end

  defp light_companies do
    Company
    |> where([c], c.status != "trashed")
    |> order_by([c], asc: c.inserted_at, asc: c.uuid)
    |> select([c], struct(c, [:uuid, :name, :status, :inserted_at]))
    |> repo().all()
  end

  # Interaction has no soft-delete field of its own — an interaction is live
  # for move-planning unless its anchor (contact or company) is trashed
  # (D8); those are handled separately by `trashed_anchor_orphan_actions/0`.
  defp light_interactions do
    Interaction
    |> join(:left, [i], c in Contact, on: i.contact_uuid == c.uuid)
    |> join(:left, [i, _c], co in Company, on: i.company_uuid == co.uuid)
    |> where(
      [i, c, co],
      (is_nil(i.contact_uuid) or c.status != "trashed") and
        (is_nil(i.company_uuid) or co.status != "trashed")
    )
    |> order_by([i], asc: i.inserted_at, asc: i.uuid)
    |> select([i], struct(i, [:uuid, :subject, :contact_uuid, :company_uuid, :inserted_at]))
    |> repo().all()
  end

  # ── Interactions anchored to a trashed contact/company (D8) ─────

  # Such an interaction is skipped by move-planning above (never in
  # `light_interactions/0`, so the parent hook is never called for it — same
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
      |> order_by([i], asc: i.inserted_at, asc: i.uuid)
      |> select([i], struct(i, [:uuid, :subject]))
      |> repo().all()
      |> Enum.map(&{&1, "contact"})

    company_trashed =
      Interaction
      |> join(:inner, [i], co in Company,
        on: i.company_uuid == co.uuid and co.status == "trashed"
      )
      |> order_by([i], asc: i.inserted_at, asc: i.uuid)
      |> select([i], struct(i, [:uuid, :subject]))
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
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
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

  # One query per record kind present among the candidates (R9: only the
  # column an orphan report needs — the record's status, or presence for
  # interactions, which have no status column of their own).
  defp load_candidate_records(candidates) do
    by_kind =
      Enum.group_by(
        candidates,
        fn {_folder, {kind, _uuid}} -> kind end,
        fn {_folder, {_kind, uuid}} -> uuid end
      )

    %{}
    |> Map.merge(load_record_statuses(Contact, :contact, Map.get(by_kind, :contact, [])))
    |> Map.merge(load_record_statuses(Company, :company, Map.get(by_kind, :company, [])))
    |> Map.merge(load_interaction_presence(Map.get(by_kind, :interaction, [])))
  end

  defp load_record_statuses(_schema, _kind, []), do: %{}

  defp load_record_statuses(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> select([r], {r.uuid, r.status})
    |> repo().all()
    |> Map.new(fn {uuid, status} -> {{kind, uuid}, status} end)
  end

  defp load_interaction_presence([]), do: %{}

  defp load_interaction_presence(uuids) do
    Interaction
    |> where([i], i.uuid in ^uuids)
    |> select([i], i.uuid)
    |> repo().all()
    |> Map.new(&{{:interaction, &1}, :live})
  end

  defp orphan_action({folder, {kind, uuid}}, records_by_key, counts) do
    value = Map.get(records_by_key, {kind, uuid})

    if orphan?(kind, value) do
      folder_counts = folder_counts(counts, folder.uuid)

      %{
        source: @source,
        kind: :orphan,
        op: :report,
        label: folder.name,
        folder: folder,
        counts: folder_counts,
        reason: orphan_reason(value, folder_counts)
      }
    end
  end

  # No record at all → orphan. A found `Interaction` row is always live here
  # (its trashed-anchor case never reaches this path, see
  # `light_interactions/0` above). Contact/Company use the shared "trashed"
  # sentinel.
  defp orphan?(:interaction, value), do: is_nil(value)
  defp orphan?(_kind, nil), do: true
  defp orphan?(_kind, "trashed"), do: true
  defp orphan?(_kind, _status), do: false

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"
  defp orphan_reason(status, {files, _links}), do: "record status #{status}, #{files} file(s)"

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
          PhoenixKit.Modules.Storage.File
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
