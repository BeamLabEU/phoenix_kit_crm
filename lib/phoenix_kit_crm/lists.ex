defmodule PhoenixKitCRM.Lists do
  @moduledoc """
  Context for CRM contact lists (`PhoenixKitCRM.Schemas.ContactList`) and
  their memberships (`PhoenixKitCRM.Schemas.ListMember`).

  Modeled on `PhoenixKitCRM.PartyRoles` (soft-toggle mutations, `actor_uuid`
  audit via `PhoenixKitCRM.Activity`) with one deliberate divergence: unlike
  PartyRoles, this context broadcasts over PubSub (`PhoenixKitCRM.PubSub`,
  topic `crm:lists`) after every list/membership mutation — the admin UI
  shows live subscriber counters, so a live-updating feed is worth the extra
  moving part here even though PartyRoles didn't need one.

  Membership is never hard-deleted: `remove_from_list/2,3` flips `status` to
  `"removed"` and stamps `unsubscribed_at`, same as a list's `archive_list/1,2`
  only flips `status` rather than deleting the row. This keeps list history
  (and the `idx_crm_list_members_list_email` email slot — see the schema
  moduledoc) intact.

  Opt-out/consent live on the **contact**, not the membership — an opt-out
  applies across every list the contact belongs to. The Stage-4 send path is
  expected to check membership `status == "subscribed"` AND
  `contact.opted_out_at == nil`.

  `subscriber_count` is a maintained cache, kept in sync here via atomic
  `UPDATE ... SET subscriber_count = subscriber_count + $1` on every
  membership add/remove; `recount_list/1` is the repair function if it ever
  drifts.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.Activity
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.PubSub
  alias PhoenixKitCRM.Schemas.{Contact, ContactList, ListMember}
  alias PhoenixKitCRM.Search

  # See members_by_email/3's doc for why this exists.
  @members_by_email_chunk_size 10_000

  defp repo, do: RepoHelper.repo()

  # ── Lists CRUD ──────────────────────────────────────────────────────

  @spec change_list(ContactList.t(), map()) :: Ecto.Changeset.t()
  def change_list(%ContactList{} = list, attrs \\ %{}), do: ContactList.changeset(list, attrs)

  @doc "Creates a list. Pass `:actor_uuid` in `opts` for the activity log entry."
  @spec create_list(map(), keyword()) :: {:ok, ContactList.t()} | {:error, Ecto.Changeset.t()}
  def create_list(attrs, opts \\ []) do
    %ContactList{}
    |> ContactList.changeset(attrs)
    |> repo().insert()
    |> log_on_ok("crm.list_created", opts)
    |> broadcast_on_ok(:list_created, &list_payload/1)
  end

  @doc "Updates a list. Pass `:actor_uuid` in `opts` for the activity log entry."
  @spec update_list(ContactList.t(), map(), keyword()) ::
          {:ok, ContactList.t()} | {:error, Ecto.Changeset.t()}
  def update_list(%ContactList{} = list, attrs, opts \\ []) do
    list
    |> ContactList.changeset(attrs)
    |> repo().update()
    |> log_on_ok("crm.list_updated", opts)
    |> broadcast_on_ok(:list_updated, &list_payload/1)
  end

  @doc "Archives a list (status flip, not delete). Idempotent if already archived."
  @spec archive_list(ContactList.t(), keyword()) ::
          {:ok, ContactList.t()} | {:error, Ecto.Changeset.t()}
  def archive_list(list, opts \\ [])
  def archive_list(%ContactList{status: "archived"} = list, _opts), do: {:ok, list}

  def archive_list(%ContactList{} = list, opts) do
    list
    |> change(status: "archived")
    |> repo().update()
    |> log_on_ok("crm.list_archived", opts)
    |> broadcast_on_ok(:list_archived, &list_payload/1)
  end

  @doc "Unarchives a list back to active. Idempotent if already active."
  @spec unarchive_list(ContactList.t(), keyword()) ::
          {:ok, ContactList.t()} | {:error, Ecto.Changeset.t()}
  def unarchive_list(list, opts \\ [])
  def unarchive_list(%ContactList{status: "active"} = list, _opts), do: {:ok, list}

  def unarchive_list(%ContactList{} = list, opts) do
    list
    |> change(status: "active")
    |> repo().update()
    |> log_on_ok("crm.list_unarchived", opts)
    |> broadcast_on_ok(:list_unarchived, &list_payload/1)
  end

  @doc """
  Lists contact lists, name ascending.

  ## Options
    * `:status` — filter to one status (default: all)
    * `:subscribable` — filter to `subscribable == true/false` (default: all)
  """
  @spec list_lists(keyword()) :: [ContactList.t()]
  def list_lists(opts \\ []) do
    ContactList
    |> maybe_filter_status(opts)
    |> maybe_filter_subscribable(opts)
    |> order_by([l], asc: l.name)
    |> repo().all()
  end

  @doc "Same `:status` / `:subscribable` filters as `list_lists/1`, as a count."
  @spec count_lists(keyword()) :: non_neg_integer()
  def count_lists(opts \\ []) do
    ContactList
    |> maybe_filter_status(opts)
    |> maybe_filter_subscribable(opts)
    |> repo().aggregate(:count, :uuid)
  end

  @spec get_list(UUIDv7.t() | String.t() | nil) :: ContactList.t() | nil
  def get_list(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> repo().get(ContactList, uuid)
      :error -> nil
    end
  end

  @spec get_list!(UUIDv7.t() | String.t()) :: ContactList.t()
  def get_list!(uuid), do: repo().get!(ContactList, uuid)

  @spec get_list_by_slug(String.t() | nil) :: ContactList.t() | nil
  def get_list_by_slug(nil), do: nil
  def get_list_by_slug(slug), do: repo().get_by(ContactList, slug: slug)

  # ── Membership ──────────────────────────────────────────────────────

  @doc """
  Adds a contact to a list — writes a membership snapshotting the contact's
  current email (may be `nil`; the contact is just unsendable). Sets
  `subscribed_at` and bumps the list's `subscriber_count`.

  `idx_crm_list_members_list_contact` has no status predicate — once a
  contact has ever had a row for a list (even a `removed` one), that
  `(list_uuid, contact_uuid)` slot is occupied at the DB level forever. So
  a blind insert here would raise `:already_member` for a contact that
  isn't currently a member at all. Mirrors `PartyRoles.grant_role/3`: looks
  the row up first — no row → insert; a `removed`/`pending` row →
  reactivate it in place (status → `"subscribed"`, refreshed
  `subscribed_at`/`source`/`email`, `unsubscribed_at` cleared); an already
  `"subscribed"` row → `{:error, :already_member}` (a real no-op, not a
  reactivation).

  ## Options
    * `:source` — one of `PhoenixKitCRM.Schemas.ListMember.sources/0` (default `"manual"`)
    * `:actor_uuid` — for the activity log entry

  Returns `{:error, :already_member}` if the contact is already an active
  member, or `{:error, :email_already_in_list}` if a *different* contact
  already holds this email in the list (the `idx_crm_list_members_list_email`
  race-shaped case — a `removed` member still holds its email slot).
  """
  @spec add_contact_to_list(Contact.t(), ContactList.t(), keyword()) ::
          {:ok, ListMember.t()}
          | {:error, :already_member | :email_already_in_list | Ecto.Changeset.t()}
  def add_contact_to_list(%Contact{} = contact, %ContactList{} = list, opts \\ []) do
    case get_member(list, contact) do
      nil -> insert_member(contact, list, opts)
      %ListMember{status: "subscribed"} -> {:error, :already_member}
      %ListMember{} = existing -> reactivate_member(existing, contact, list, opts)
    end
  end

  defp insert_member(contact, list, opts) do
    source = Keyword.get(opts, :source, "manual")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      "list_uuid" => list.uuid,
      "contact_uuid" => contact.uuid,
      "source" => source,
      "status" => "subscribed",
      "subscribed_at" => now
    }

    changeset =
      %ListMember{}
      |> ListMember.changeset(attrs)
      |> change(email: contact.email)

    case repo().insert(changeset) do
      {:ok, member} -> finalize_added(member, list, contact, opts)
      {:error, cs} -> classify_membership_error(cs)
    end
  end

  defp reactivate_member(existing, contact, list, opts) do
    source = Keyword.get(opts, :source, "manual")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The WHERE guard and the write must be the SAME statement, or a
    # SELECT-then-UPDATE has a TOCTOU window: two concurrent reactivations
    # of the same removed/pending row could both read "not subscribed"
    # before either commits, and both would then bump subscriber_count — a
    # double-increment for one real reactivation. update_all bypasses
    # ListMember.changeset/2, so this loses validate_inclusion/3 on
    # :source (acceptable — :source only ever arrives from trusted internal
    # callers, never raw form params — see add_contact_to_list/3's
    # moduledoc) AND the changeset's unique_constraint/3 translation of a
    # DB-level violation into a friendly error tuple, which the rescue
    # below restores for :email — reactivating can still collide with a
    # DIFFERENT row already holding this contact's (possibly since-changed)
    # email in the same list.
    {n, _} =
      ListMember
      |> where([m], m.uuid == ^existing.uuid and m.status != "subscribed")
      |> repo().update_all(
        set: [
          status: "subscribed",
          subscribed_at: now,
          unsubscribed_at: nil,
          source: source,
          email: contact.email,
          updated_at: now
        ]
      )

    case n do
      1 -> finalize_added(repo().get!(ListMember, existing.uuid), list, contact, opts)
      0 -> {:error, :already_member}
    end
  rescue
    e in Postgrex.Error ->
      case e.postgres && e.postgres.constraint do
        "idx_crm_list_members_list_email" -> {:error, :email_already_in_list}
        _ -> reraise e, __STACKTRACE__
      end
  end

  defp finalize_added(member, list, contact, opts) do
    updated_list = bump_counter(list, 1)

    Activity.log("crm.list_member_added",
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "crm_list_member",
      resource_uuid: member.uuid,
      metadata: %{"list_uuid" => list.uuid, "contact_uuid" => contact.uuid}
    )

    PubSub.broadcast_list_event(:member_added, member_payload(member, updated_list))
    {:ok, member}
  end

  @doc """
  Creates a brand-new contact and adds it to `list`, both in ONE transaction
  — used by `PhoenixKitCRM.Lists.Import` so a membership-uniqueness violation
  rolls back the just-created contact too (no orphan contacts on a
  failed/duplicate import row). Delegates to `Contacts.create_contact/1` for
  the contact insert and `add_contact_to_list/3` for the membership; never
  duplicates either's logic.

  Note: `add_contact_to_list/3`'s activity log + PubSub broadcast fire from
  *inside* this transaction (right before it commits, not after) — an
  acceptable, negligible-window tradeoff for reusing it here rather than
  duplicating its insert + counter-bump logic.

  Returns `{:error, :already_member}` / `{:error, :email_already_in_list}`
  exactly like `add_contact_to_list/3` (structurally `:already_member` can't
  actually happen here — the contact is always brand-new — but the type
  stays honest about what `add_contact_to_list/3` can return), or
  `{:error, changeset}` from a failed contact insert.
  """
  @spec add_new_contact_to_list(map(), ContactList.t(), keyword()) ::
          {:ok, {Contact.t(), ListMember.t()}}
          | {:error, :already_member | :email_already_in_list | Ecto.Changeset.t()}
  def add_new_contact_to_list(contact_attrs, %ContactList{} = list, opts \\ []) do
    repo().transaction(fn ->
      with {:ok, contact} <- Contacts.create_contact(contact_attrs),
           {:ok, member} <- add_contact_to_list(contact, list, opts) do
        {contact, member}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  @doc """
  The member (any status) currently holding `email` in `list`, if any, with
  `:contact` preloaded. Used by the importer to classify an
  `idx_crm_list_members_list_email` violation as `:already_in_list` (an
  active/pending member) vs `:unsubscribed` (a `"removed"` member still
  holding the slot), and by the manual add-by-email form to offer a
  "Resubscribe" affordance for the `:unsubscribed` case instead of a blocked
  add (`add_new_contact_to_list/3` would just fail there — the slot is held).
  """
  @spec get_member_by_email(ContactList.t(), String.t()) :: ListMember.t() | nil
  def get_member_by_email(%ContactList{} = list, email) when is_binary(email) do
    ListMember
    |> repo().get_by(list_uuid: list.uuid, email: email)
    |> case do
      nil -> nil
      member -> repo().preload(member, :contact)
    end
  end

  @doc """
  Batched counterpart to `get_member_by_email/2` — members (any status)
  holding any of the given `emails` in `list`, as an `%{email => member}`
  map. One query instead of N; built for `Lists.Import`'s dry-run preview,
  which used to call `get_member_by_email/2` once per row — fine for a
  handful of rows, but a file near the upload size limit could mean tens of
  thousands of sequential round trips inside a single, unyielding LiveView
  event. Unlike `get_member_by_email/2`, `:contact` is NOT preloaded here —
  the only caller (`Import.preview_row/2`) classifies purely on `status`.

  Map keys are downcased (matching citext's case-insensitive comparison,
  but the *stored* `email` column value keeps whatever case it was written
  in, so a raw `Map.new(&{&1.email, &1})` could silently miss a lookup) —
  callers must downcase their own lookup key too.

  `emails` is queried in chunks of `chunk_size` (default
  #{@members_by_email_chunk_size}) rather than one `WHERE email IN (...)`
  for the whole list: Ecto expands `field in ^list` into one bind
  parameter PER element, and Postgres caps a single query at 65,535 bind
  parameters — a file near the upload size limit (one address per line)
  would blow past that in a single query and raise `Postgrex.Error`
  instead of rendering the import preview. `chunk_size` is exposed so
  tests can exercise the chunking/merge behavior without a multi-thousand
  row fixture.
  """
  @spec members_by_email(ContactList.t(), [String.t()], pos_integer()) :: %{
          String.t() => ListMember.t()
        }
  def members_by_email(list, emails, chunk_size \\ @members_by_email_chunk_size)

  def members_by_email(_list, [], _chunk_size), do: %{}

  def members_by_email(%ContactList{} = list, emails, chunk_size)
      when is_list(emails) and is_integer(chunk_size) and chunk_size > 0 do
    emails
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(%{}, fn chunk, acc ->
      chunk_members =
        ListMember
        |> where([m], m.list_uuid == ^list.uuid and m.email in ^chunk)
        |> repo().all()
        |> Map.new(&{String.downcase(&1.email), &1})

      Map.merge(acc, chunk_members)
    end)
  end

  @doc """
  Removes a contact's membership from a list (soft: `status` → `"removed"`,
  stamps `unsubscribed_at`). Never deletes the row. Idempotent if already
  removed. `opts` accepts `:actor_uuid`.

  Accepts either an existing `ListMember` directly, or a `contact` + `list`
  pair to look one up.
  """
  @spec remove_from_list(ListMember.t(), keyword()) :: {:ok, ListMember.t()}
  def remove_from_list(member, opts \\ [])
  def remove_from_list(%ListMember{status: "removed"} = member, _opts), do: {:ok, member}

  def remove_from_list(%ListMember{} = member, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case remove_member_row(member.uuid, now) do
      :already_removed ->
        {:ok, repo().get!(ListMember, member.uuid)}

      was_subscribed? when is_boolean(was_subscribed?) ->
        updated = repo().get!(ListMember, member.uuid)
        list = repo().get!(ContactList, updated.list_uuid)
        updated_list = if was_subscribed?, do: bump_counter(list, -1), else: list

        Activity.log("crm.list_member_removed",
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "crm_list_member",
          resource_uuid: updated.uuid,
          metadata: %{"list_uuid" => updated.list_uuid, "contact_uuid" => updated.contact_uuid}
        )

        PubSub.broadcast_list_event(:member_removed, member_payload(updated, updated_list))
        {:ok, updated}
    end
  end

  # Atomic conditional-update pattern (same reasoning as reactivate_member/4
  # above): the decision of "was this member subscribed" and the write
  # itself must be the SAME statement, or two concurrent removes of the
  # same member (two browser tabs) could both read "subscribed" before
  # either commits and both decrement the counter. The first update_all
  # only matches a row still "subscribed" at the moment it runs; if a
  # concurrent call already flipped it, this one falls through to the
  # "pending" branch instead of double-counting, and that one falls through
  # to :already_removed if a THIRD concurrent call got there first.
  #
  # Returns true (was "subscribed", counter must move), false (was
  # "pending", never counted), or :already_removed (idempotent no-op).
  defp remove_member_row(uuid, now) do
    {n_subscribed, _} =
      ListMember
      |> where([m], m.uuid == ^uuid and m.status == "subscribed")
      |> repo().update_all(set: [status: "removed", unsubscribed_at: now, updated_at: now])

    if n_subscribed == 1 do
      true
    else
      {n_pending, _} =
        ListMember
        |> where([m], m.uuid == ^uuid and m.status != "removed")
        |> repo().update_all(set: [status: "removed", unsubscribed_at: now, updated_at: now])

      if n_pending == 1, do: false, else: :already_removed
    end
  end

  @doc """
  Same as `remove_from_list/2`, but looks the membership up by contact + list
  instead of taking an existing `ListMember` directly. `opts` is required here
  (not defaulted) to avoid an arity clash with the single-struct form above —
  pass `[]` for no options.
  """
  @spec remove_from_list(Contact.t(), ContactList.t(), keyword()) ::
          {:ok, ListMember.t()} | {:error, :not_member}
  def remove_from_list(%Contact{} = contact, %ContactList{} = list, opts) do
    case get_member(list, contact) do
      nil -> {:error, :not_member}
      %ListMember{} = member -> remove_from_list(member, opts)
    end
  end

  @doc "Whether the contact currently has an active (`subscribed`) membership on the list."
  @spec subscribed?(Contact.t(), ContactList.t()) :: boolean()
  def subscribed?(%Contact{} = contact, %ContactList{} = list) do
    ListMember
    |> where(
      [m],
      m.list_uuid == ^list.uuid and m.contact_uuid == ^contact.uuid and m.status == "subscribed"
    )
    |> repo().exists?()
  end

  @doc """
  Lists a list's memberships, newest first, contact preloaded.

  ## Options
    * `:status` — filter to one status (default: all)
    * `:search` — case-insensitive match on the member's email or its contact's name
    * `:limit` / `:offset` — pagination
  """
  @spec list_members(ContactList.t(), keyword()) :: [ListMember.t()]
  def list_members(%ContactList{} = list, opts \\ []) do
    ListMember
    |> where([m], m.list_uuid == ^list.uuid)
    |> maybe_filter_member_status(opts)
    |> maybe_search_members(opts)
    |> order_by([m], desc: m.inserted_at)
    |> maybe_paginate(opts)
    |> repo().all()
    |> repo().preload(:contact)
  end

  @doc """
  Recomputes and stores `subscriber_count` from the actual subscribed-member
  count. Repair function. Returns `:missing` when the list row no longer
  exists by the time the write runs (deleted concurrently) — nothing left
  to repair, and no `:list_recounted` event is broadcast.
  """
  @spec recount_list(ContactList.t()) :: ContactList.t() | :missing
  def recount_list(%ContactList{} = list) do
    count =
      ListMember
      |> where([m], m.list_uuid == ^list.uuid and m.status == "subscribed")
      |> repo().aggregate(:count, :uuid)

    case set_counter(list, count) do
      {:ok, updated_list} ->
        PubSub.broadcast_list_event(:list_recounted, list_payload(updated_list))
        updated_list

      :missing ->
        :missing
    end
  end

  @doc """
  Preview counts for `apply_locale_to_members/3`, over the list's currently
  `"subscribed"` members:

    * `total` — how many members `:all` mode would touch.
    * `missing_locale` — how many of those have no locale yet (`NULL` or
      `""`) — how many `:missing_only` mode would touch. Deliberately a
      SEPARATE count rather than deriving the modal's "will be affected"
      number from `total` alone: `:missing_only` is the default mode, and
      touches a strict subset of `total` whenever `different_locale` > 0 —
      showing `total` regardless of the selected mode overstates the
      impact for the common case.
    * `different_locale` — how many already carry a DIFFERENT, non-blank
      locale than the list's. What makes "all" (overwrite) a real, visible
      tradeoff in the confirm UI rather than a blind guess.

  `%{total: 0, missing_locale: 0, different_locale: 0}` when the list
  itself has no locale set (nothing to preview — the UI should already
  gate the action on this).
  """
  @spec locale_apply_preview(ContactList.t()) :: %{
          total: non_neg_integer(),
          missing_locale: non_neg_integer(),
          different_locale: non_neg_integer()
        }
  def locale_apply_preview(%ContactList{locale: locale}) when locale in [nil, ""],
    do: %{total: 0, missing_locale: 0, different_locale: 0}

  def locale_apply_preview(%ContactList{} = list) do
    subscribed_members =
      ListMember
      |> join(:inner, [m], c in Contact, on: c.uuid == m.contact_uuid)
      |> where([m, c], m.list_uuid == ^list.uuid and m.status == "subscribed")

    total = subscribed_members |> select([m, _c], count(m.uuid)) |> repo().one()

    missing_locale =
      subscribed_members
      |> where([_m, c], is_nil(c.locale) or c.locale == "")
      |> select([m, _c], count(m.uuid))
      |> repo().one()

    different_locale =
      subscribed_members
      |> where([_m, c], not is_nil(c.locale) and c.locale != "" and c.locale != ^list.locale)
      |> select([m, _c], count(m.uuid))
      |> repo().one()

    %{total: total, missing_locale: missing_locale, different_locale: different_locale}
  end

  @doc """
  Bulk-writes the list's `locale` onto its `"subscribed"` members' contacts.

  `mode`:
    * `:missing_only` — only contacts with no locale set yet (`NULL` or `""`).
    * `:all` — every subscribed member's contact, overwriting any existing
      locale — including one set by a DIFFERENT list this same contact also
      belongs to. `locale` lives on the contact, not the membership, so it
      is never list-scoped: the last list to apply its locale to a shared
      contact wins. That's expected, not a bug.

  Pass `:actor_uuid` in `opts` for the activity log entry (logged once per
  call, with the affected count in `metadata` — not once per contact, same
  as the list-level mutations in this module). Also broadcasts a single
  `:list_locale_applied` event over `crm:lists` (payload:
  `%{list_uuid:, locale:, mode:, updated_count:}`) when `updated_count > 0`
  — this bulk mutation used to be the only one in this context that didn't,
  unlike every other list/membership write here (see the module doc).

  Returns `{:ok, updated_count}` (`0` is a valid, non-error result — e.g.
  `:missing_only` against a list where every member already has a locale;
  no event fires in that case either, mirroring the activity log's own
  `count > 0` guard), or `{:error, :no_locale}` if the list itself has no
  locale (defensive; the UI should already gate the triggering action on
  this).
  """
  @spec apply_locale_to_members(ContactList.t(), :all | :missing_only, keyword()) ::
          {:ok, non_neg_integer()} | {:error, :no_locale}
  def apply_locale_to_members(list, mode, opts \\ [])

  def apply_locale_to_members(%ContactList{locale: locale}, _mode, _opts)
      when locale in [nil, ""],
      do: {:error, :no_locale}

  def apply_locale_to_members(%ContactList{} = list, mode, opts)
      when mode in [:all, :missing_only] do
    member_contact_uuids =
      from(m in ListMember,
        where: m.list_uuid == ^list.uuid and m.status == "subscribed",
        select: m.contact_uuid
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Contact
      |> where([c], c.uuid in subquery(member_contact_uuids))
      |> maybe_only_missing_locale(mode)
      |> repo().update_all(set: [locale: list.locale, updated_at: now])

    if count > 0 do
      Activity.log("crm.list_locale_applied",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: "crm_list",
        resource_uuid: list.uuid,
        metadata: %{
          "locale" => list.locale,
          "mode" => Atom.to_string(mode),
          "updated_count" => count
        }
      )

      PubSub.broadcast_list_event(:list_locale_applied, locale_applied_payload(list, mode, count))
    end

    {:ok, count}
  end

  defp maybe_only_missing_locale(query, :missing_only),
    do: where(query, [c], is_nil(c.locale) or c.locale == "")

  defp maybe_only_missing_locale(query, :all), do: query

  @doc """
  Contacts with an active (`"subscribed"`) membership on EVERY one of the
  given lists — the CRM comparison screen's cross-list overlap report.
  Requires at least 2 list uuids (an "overlap" of one list is just that
  list's members, not a comparison). Malformed uuids are dropped (returns
  `[]` if fewer than 2 valid ones remain) and trashed contacts are excluded.
  """
  @spec list_overlap([UUIDv7.t() | String.t()]) :: [Contact.t()]
  def list_overlap(list_uuids) when is_list(list_uuids) and length(list_uuids) >= 2 do
    # Drop malformed ids so one forged element can't raise an Ecto cast error
    # (same reasoning as Contacts.list_by_uuids/1).
    case list_uuids |> Enum.uniq() |> Enum.filter(&valid_uuid?/1) do
      valid when length(valid) >= 2 ->
        wanted = length(valid)

        ListMember
        |> where([m], m.list_uuid in ^valid and m.status == "subscribed")
        |> group_by([m], m.contact_uuid)
        |> having([m], count(m.list_uuid, :distinct) == ^wanted)
        |> select([m], m.contact_uuid)
        |> repo().all()
        |> Contacts.list_by_uuids()
        # Trashing a contact leaves its memberships "subscribed"; don't
        # surface trashed contacts in the overlap report (the sibling
        # duplicate-email report excludes them too).
        |> Enum.reject(&(&1.status == "trashed"))

      _ ->
        []
    end
  end

  defp get_member(%ContactList{} = list, %Contact{} = contact) do
    repo().get_by(ListMember, list_uuid: list.uuid, contact_uuid: contact.uuid)
  end

  # A single INSERT/UPDATE can only ever trip one of these two unique
  # constraints, so there's no real ambiguity between the branches below —
  # whichever one Postgres actually reports is the one that gets an error
  # added to `errors` by the matching `unique_constraint/3` in
  # `ListMember.changeset/2`.
  defp classify_membership_error(%Ecto.Changeset{errors: errors} = cs) do
    cond do
      Keyword.has_key?(errors, :email) ->
        {:error, :email_already_in_list}

      Keyword.has_key?(errors, :list_uuid) or Keyword.has_key?(errors, :contact_uuid) ->
        {:error, :already_member}

      true ->
        {:error, cs}
    end
  end

  defp bump_counter(%ContactList{uuid: uuid}, delta) do
    {1, _} =
      ContactList
      |> where([l], l.uuid == ^uuid)
      |> repo().update_all(inc: [subscriber_count: delta])

    repo().get!(ContactList, uuid)
  end

  # Branches on the matched-row count instead of asserting `{1, _}` (the
  # idiom used for membership transitions above): a 0-row UPDATE means the
  # list was deleted between the caller loading it and this statement — a
  # real TOCTOU inside `Contacts.delete_contact/1`'s transaction, where
  # rolling back a whole contact deletion over a moot counter would be
  # wrong. Callers that want the old hard guarantee can match on `:missing`.
  defp set_counter(%ContactList{uuid: uuid}, count) do
    case ContactList
         |> where([l], l.uuid == ^uuid)
         |> repo().update_all(set: [subscriber_count: count]) do
      {1, _} -> {:ok, repo().get!(ContactList, uuid)}
      {0, _} -> :missing
    end
  end

  # ── Contact-level opt-out / consent ──────────────────────────────────

  @doc """
  Opts a contact out — sets `opted_out_at` and appends an entry to `consent`
  (`ts`/`action`/`actor_uuid`/`source`). Applies across every list the
  contact belongs to (the send path checks this, not per-membership status).
  Idempotent: a no-op if already opted out.

  ## Options
    * `:source` — free-form origin tag (e.g. `"admin"`, `"unsubscribe_link"`); default `"manual"`
    * `:actor_uuid` — for the activity log entry
  """
  @spec opt_out(Contact.t(), keyword()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def opt_out(contact, opts \\ [])

  def opt_out(%Contact{opted_out_at: opted_out_at} = contact, _opts)
      when not is_nil(opted_out_at),
      do: {:ok, contact}

  def opt_out(%Contact{} = contact, opts) do
    contact
    |> set_consent("opt_out", opts)
    |> broadcast_on_ok(:contact_opt_out, &contact_payload/1)
  end

  @doc """
  Opts a contact back in — clears `opted_out_at` and appends a `consent`
  entry. Idempotent: a no-op if not currently opted out.
  """
  @spec opt_in(Contact.t(), keyword()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def opt_in(contact, opts \\ [])
  def opt_in(%Contact{opted_out_at: nil} = contact, _opts), do: {:ok, contact}

  def opt_in(%Contact{} = contact, opts) do
    contact
    |> set_consent("opt_in", opts)
    |> broadcast_on_ok(:contact_opt_in, &contact_payload/1)
  end

  defp set_consent(contact, action, opts) do
    source = Keyword.get(opts, :source, "manual")
    actor_uuid = Keyword.get(opts, :actor_uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entry = %{
      "ts" => DateTime.to_iso8601(now),
      "action" => action,
      "actor_uuid" => actor_uuid,
      "source" => source
    }

    opted_out_at = if action == "opt_out", do: now, else: nil

    contact
    |> change(opted_out_at: opted_out_at, consent: append_consent(contact.consent, entry))
    |> repo().update()
    |> log_on_ok("crm.contact_#{action}", opts, "crm_contact", contact.uuid)
  end

  defp append_consent(consent, entry) when is_map(consent) do
    log = Map.get(consent, "log", [])
    Map.put(consent, "log", log ++ [entry])
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp maybe_filter_status(query, opts) do
    case Keyword.get(opts, :status) do
      nil -> query
      status -> where(query, [l], l.status == ^status)
    end
  end

  defp maybe_filter_subscribable(query, opts) do
    case Keyword.get(opts, :subscribable) do
      nil -> query
      subscribable -> where(query, [l], l.subscribable == ^subscribable)
    end
  end

  defp maybe_filter_member_status(query, opts) do
    case Keyword.get(opts, :status) do
      nil -> query
      status -> where(query, [m], m.status == ^status)
    end
  end

  defp maybe_search_members(query, opts) do
    case Keyword.get(opts, :search) do
      term when is_binary(term) ->
        case String.trim(term) do
          "" ->
            query

          trimmed ->
            like = Search.like_pattern(trimmed)

            query
            |> join(:left, [m], c in Contact, on: c.uuid == m.contact_uuid)
            |> where([m, c], ilike(m.email, ^like) or ilike(c.name, ^like))
        end

      _ ->
        query
    end
  end

  defp maybe_paginate(query, opts) do
    query
    |> maybe_limit(Keyword.get(opts, :limit))
    |> maybe_offset(Keyword.get(opts, :offset))
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  defp log_on_ok({:ok, %ContactList{} = list} = ok, action, opts) do
    Activity.log(action,
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: "crm_list",
      resource_uuid: list.uuid,
      metadata: %{"name" => list.name, "slug" => list.slug}
    )

    ok
  end

  defp log_on_ok(error, _action, _opts), do: error

  defp log_on_ok({:ok, %Contact{}} = ok, action, opts, resource_type, resource_uuid) do
    Activity.log(action,
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      metadata: %{}
    )

    ok
  end

  defp log_on_ok(error, _action, _opts, _resource_type, _resource_uuid), do: error

  defp broadcast_on_ok({:ok, entity} = ok, event, payload_fun) do
    PubSub.broadcast_list_event(event, payload_fun.(entity))
    ok
  end

  defp broadcast_on_ok(error, _event, _payload_fun), do: error

  defp list_payload(%ContactList{} = list) do
    %{list_uuid: list.uuid, subscriber_count: list.subscriber_count, status: list.status}
  end

  defp contact_payload(%Contact{} = contact) do
    %{contact_uuid: contact.uuid, opted_out_at: contact.opted_out_at}
  end

  defp member_payload(%ListMember{} = member, %ContactList{} = list) do
    %{
      list_uuid: list.uuid,
      member_uuid: member.uuid,
      subscriber_count: list.subscriber_count,
      status: member.status
    }
  end

  defp locale_applied_payload(%ContactList{} = list, mode, count) do
    %{list_uuid: list.uuid, locale: list.locale, mode: mode, updated_count: count}
  end

  defp valid_uuid?(uuid), do: match?({:ok, _}, Ecto.UUID.cast(uuid))
end
