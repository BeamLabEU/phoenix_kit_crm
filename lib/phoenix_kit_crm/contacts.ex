defmodule PhoenixKitCRM.Contacts do
  @moduledoc """
  Context for CRM contacts — CRUD, soft-delete, the (v1 single) company
  membership, and the **optional** login-user connection.

  The user connection mirrors `phoenix_kit_staff`'s flow but is opt-in: a
  contact has no `user_uuid` until `connect_user/2` is called (driven by the
  form's "allow login" checkbox). It uses find-or-create — an existing user
  by email is linked; if none exists a placeholder is registered (tagged
  `custom_fields.source = "crm_contact"`), which the person can later claim by
  registering / signing in with that email.
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Lists
  alias PhoenixKitCRM.Mirror
  alias PhoenixKitCRM.PartyRoles
  alias PhoenixKitCRM.Schemas.{CompanyMembership, Contact, ContactList, ListMember}
  alias PhoenixKitCRM.Search
  alias PhoenixKitCRM.SoftDelete

  defp repo, do: RepoHelper.repo()

  @placeholder_source "crm_contact"

  # ── Queries ─────────────────────────────────────────────────────────

  @doc """
  Lists contacts. Excludes trashed by default; preloads the primary company
  membership (with company) and the linked user.

  ## Options
    * `:status` / `:include_trashed` — see `apply_status_scope/2`
    * `:search` — name/email ILIKE match (case-insensitive)
    * `:limit` / `:offset` — pagination; both no-ops when absent, so this
      stays a full unpaginated list for any existing caller not passing them
  """
  @spec list_contacts(keyword()) :: [Contact.t()]
  def list_contacts(opts \\ []) do
    Contact
    |> apply_status_scope(opts)
    |> maybe_search_contacts(opts)
    |> order_by([c], asc: c.name)
    |> maybe_paginate(opts)
    |> repo().all()
    |> repo().preload(company_memberships: :company, user: [])
  end

  @doc "Contacts for the given uuids (any status) — for comment back-link resolution."
  @spec list_by_uuids([binary()]) :: [Contact.t()]
  def list_by_uuids([]), do: []

  def list_by_uuids(uuids) when is_list(uuids) do
    # Drop malformed ids so one bad element can't raise an Ecto cast error.
    case Enum.filter(uuids, &valid_uuid?/1) do
      [] -> []
      valid -> from(c in Contact, where: c.uuid in ^valid) |> repo().all()
    end
  end

  @doc "Same filters as `list_contacts/1` (`:status`/`:include_trashed`/`:search`); ignores `:limit`/`:offset`."
  @spec count_contacts(keyword()) :: non_neg_integer()
  def count_contacts(opts \\ []) do
    Contact
    |> apply_status_scope(opts)
    |> maybe_search_contacts(opts)
    |> repo().aggregate(:count, :uuid)
  end

  @doc """
  Groups non-trashed contacts sharing the same email (case-insensitive, via
  the column's citext type), for the CRM comparison screen's directory-wide
  duplicate-email report. Only emails held by 2+ contacts; blank/nil emails
  are never a "duplicate" (many contacts legitimately have none). Ordered by
  group size, largest first.
  """
  @spec list_duplicate_email_groups() :: [%{email: String.t(), count: pos_integer()}]
  def list_duplicate_email_groups do
    Contact
    |> where([c], not is_nil(c.email) and c.email != "" and c.status != "trashed")
    |> group_by([c], c.email)
    |> having([c], count(c.uuid) > 1)
    |> select([c], %{email: c.email, count: count(c.uuid)})
    |> order_by([c], desc: count(c.uuid))
    |> repo().all()
  end

  @doc "Non-trashed contacts holding exactly this email — the drill-down for a `list_duplicate_email_groups/0` row."
  @spec list_by_email(String.t()) :: [Contact.t()]
  def list_by_email(email) when is_binary(email) do
    Contact
    |> where([c], c.email == ^email and c.status != "trashed")
    |> order_by([c], asc: c.inserted_at)
    |> repo().all()
  end

  @spec get_contact(UUIDv7.t() | String.t() | nil) :: Contact.t() | nil
  def get_contact(uuid) do
    # Validate the UUID format first so a malformed id (bad URL / forged event)
    # returns nil instead of raising an Ecto cast error.
    with {:ok, _} <- Ecto.UUID.cast(uuid),
         %Contact{} = contact <- repo().get(Contact, uuid) do
      repo().preload(contact, company_memberships: :company, user: [])
    else
      _ -> nil
    end
  end

  @doc "The (at most one) contact linked to a given login user, or nil."
  @spec get_by_user_uuid(UUIDv7.t() | String.t() | nil) :: Contact.t() | nil
  def get_by_user_uuid(nil), do: nil

  def get_by_user_uuid(user_uuid) do
    # Format-check first so a malformed id returns nil instead of raising.
    case Ecto.UUID.cast(user_uuid) do
      {:ok, _} -> repo().get_by(Contact, user_uuid: user_uuid)
      :error -> nil
    end
  end

  @doc """
  `%{user_uuid => contact}` for the given login users — the batched form of
  `get_by_user_uuid/1`, for table views that would otherwise query once per
  row. Users with no linked contact are absent from the map.
  """
  @spec map_by_user_uuids([UUIDv7.t() | String.t()]) :: %{optional(String.t()) => Contact.t()}
  def map_by_user_uuids([]), do: %{}

  def map_by_user_uuids(user_uuids) when is_list(user_uuids) do
    # Drop malformed ids so one bad element can't raise an Ecto cast error.
    case Enum.filter(user_uuids, &valid_uuid?/1) do
      [] ->
        %{}

      valid ->
        from(c in Contact, where: c.user_uuid in ^valid)
        |> repo().all()
        |> Map.new(&{&1.user_uuid, &1})
    end
  end

  @doc "The contact's primary company membership (or the first), or nil."
  @spec primary_membership(Contact.t()) :: CompanyMembership.t() | nil
  def primary_membership(%Contact{company_memberships: memberships})
      when is_list(memberships) do
    Enum.find(memberships, & &1.is_primary) || List.first(memberships)
  end

  def primary_membership(%Contact{}), do: nil

  # ── Mutations ───────────────────────────────────────────────────────

  @spec change_contact(Contact.t(), map()) :: Ecto.Changeset.t()
  def change_contact(%Contact{} = contact, attrs \\ %{}),
    do: Contact.changeset(contact, attrs)

  @spec create_contact(map()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def create_contact(attrs) do
    %Contact{}
    |> Contact.changeset(attrs)
    |> repo().insert()
  end

  @spec update_contact(Contact.t(), map()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def update_contact(%Contact{} = contact, attrs) do
    contact
    |> Contact.changeset(attrs)
    |> repo().update()
  end

  @doc "Soft-deletes a contact (status → trashed, stashing the prior status)."
  @spec trash_contact(Contact.t()) :: {:ok, Contact.t()} | {:error, atom() | Ecto.Changeset.t()}
  def trash_contact(%Contact{status: "trashed"}), do: {:error, :already_trashed}

  def trash_contact(%Contact{} = contact) do
    contact
    |> SoftDelete.trash_changeset(Contact.soft_delete_status())
    |> repo().update()
  end

  @spec restore_contact(Contact.t()) :: {:ok, Contact.t()} | {:error, atom() | Ecto.Changeset.t()}
  def restore_contact(%Contact{status: "trashed"} = contact) do
    contact
    |> SoftDelete.restore_changeset(Contact.statuses())
    |> repo().update()
  end

  def restore_contact(%Contact{}), do: {:error, :not_trashed}

  @doc """
  Permanently deletes a contact (cascades memberships + interactions at
  the DB level), keeping every affected list's `subscriber_count` in
  sync.

  The FK cascade removes `ListMember` rows entirely, bypassing
  `Lists.remove_from_list/2`'s atomic counter decrement — that path only
  exists for a live status flip (`"subscribed"` → `"removed"`), not a
  disappearing row. Without this, deleting a contact who was still
  `"subscribed"` on a list leaves that list's `subscriber_count`
  permanently overcounted (nothing else ever revisits it). Snapshots
  which lists the contact was actually `"subscribed"` on *before* the
  cascade (a `"removed"` membership was never counted, so it's excluded
  — deleting it changes nothing), then recounts exactly those lists —
  `Lists.recount_list/1`, the same repair function used for the
  Settings-page "Recount" action — in the same transaction as the
  delete itself.

  The snapshot query runs *inside* the transaction, immediately before the
  delete, rather than before `repo().transaction/1` is even called — doing
  it outside would leave a window between the snapshot and the delete where
  a concurrent `add_contact_to_list/3` could subscribe the contact to a new
  list that the snapshot never saw, permanently stranding that list's
  counter one over (the exact bug this function exists to fix, just via a
  different door).
  """
  @spec delete_contact(Contact.t()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def delete_contact(%Contact{} = contact) do
    repo().transaction(fn ->
      affected_list_uuids =
        ListMember
        |> where([m], m.contact_uuid == ^contact.uuid and m.status == "subscribed")
        |> select([m], m.list_uuid)
        |> repo().all()
        |> Enum.uniq()

      case repo().delete(contact) do
        {:ok, deleted} ->
          Enum.each(affected_list_uuids, &recount_by_uuid/1)
          # The party-role rows are soft references with no FK, so nothing
          # else removes them.
          PartyRoles.delete_roles_for("contact", contact.uuid)
          deleted

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  defp recount_by_uuid(list_uuid) do
    case repo().get(ContactList, list_uuid) do
      # The list itself was deleted concurrently (or in the same cascade,
      # if it belonged to this contact somehow) — nothing left to recount.
      nil ->
        :ok

      list ->
        # Lists.recount_list/1 SETs subscriber_count to an absolute
        # recomputed value, so it can race a concurrent
        # Lists.add_contact_to_list/2's relative `inc:` the same way any
        # other repair-recount run already can — an inherited class of
        # race, not introduced by this delete path, and not worth a
        # per-list `FOR UPDATE` lock here to close.
        #
        # `:missing` covers the narrower TOCTOU the delete_contact/1 doc
        # discusses: the list can still vanish between the repo().get/2
        # above and the recount's own UPDATE. A moot counter on a
        # deleted list must not roll back the whole contact deletion.
        case Lists.recount_list(list) do
          :missing -> :ok
          %ContactList{} -> :ok
        end
    end
  end

  @doc """
  Searches contacts by name/email (case-insensitive) for the parties picker.
  Excludes trashed and any uuids in `exclude_uuids` (e.g. the contact whose page
  the interaction is being logged on — they're already the subject).
  """
  @spec search_contacts(String.t(), pos_integer(), [binary()]) :: [Contact.t()]
  def search_contacts(query, limit \\ 8, exclude_uuids \\ []) when is_binary(query) do
    q = query |> String.replace("\x00", "") |> String.trim()

    if q == "" do
      []
    else
      like = Search.like_pattern(q)

      Contact
      |> where([c], c.status != "trashed")
      |> where([c], ilike(c.name, ^like) or ilike(c.email, ^like))
      |> maybe_exclude_uuids(exclude_uuids)
      |> order_by([c], asc: c.name)
      |> limit(^limit)
      |> repo().all()
    end
  end

  defp maybe_exclude_uuids(query, []), do: query
  defp maybe_exclude_uuids(query, uuids), do: where(query, [c], c.uuid not in ^uuids)

  # ── Company membership (v1: a single primary company per contact) ───

  @doc """
  Sets the contact's primary company membership to the given company, with
  free-form role + department. v1 manages exactly one company per contact via
  the form, so this replaces the contact's membership set. A blank/nil company
  clears it.
  """
  @spec set_primary_company(
          Contact.t(),
          UUIDv7.t() | String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) ::
          {:ok, CompanyMembership.t() | nil} | {:error, Ecto.Changeset.t()}
  def set_primary_company(%Contact{} = contact, company_uuid, _role, _department)
      when company_uuid in [nil, ""] do
    clear_memberships(contact)
    {:ok, nil}
  end

  def set_primary_company(%Contact{} = contact, company_uuid, role, department) do
    repo().transaction(fn ->
      clear_memberships(contact)

      result =
        %CompanyMembership{}
        |> CompanyMembership.changeset(%{
          "contact_uuid" => contact.uuid,
          "company_uuid" => company_uuid,
          "role_in_company" => role,
          "department" => department,
          "is_primary" => true,
          "position" => 0
        })
        |> repo().insert()

      case result do
        {:ok, membership} -> membership
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  defp clear_memberships(%Contact{uuid: uuid}) do
    from(m in CompanyMembership, where: m.contact_uuid == ^uuid) |> repo().delete_all()
  end

  # ── Optional login-user connection (staff-style find-or-create) ─────

  @doc """
  Connects a contact to a login user by email (staff-style find-or-create).
  Existing user by email → linked; otherwise a placeholder user is
  registered. Atomic: the find-or-create + link run inside one
  `repo().transaction/1`, so a just-registered placeholder is rolled back
  automatically if the link fails — no separate compensating delete (the
  prior implementation deleted by hand, which orphans the placeholder if
  that delete itself fails or the process dies mid-way). No-op-safe to
  call on an already-linked contact (re-links).
  """
  @spec connect_user(Contact.t(), String.t()) ::
          {:ok, Contact.t(), :existing | :created} | {:error, atom() | Ecto.Changeset.t()}
  def connect_user(%Contact{} = contact, email) when is_binary(email) do
    repo().transaction(fn ->
      with {:ok, user, user_status} <- find_or_create_user_by_email(email),
           {:ok, linked} <- contact |> Contact.link_user_changeset(user.uuid) |> repo().update() do
        {linked, user_status}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> case do
      {:ok, {linked, user_status}} -> {:ok, linked, user_status}
      {:error, _} = err -> err
    end
  end

  @doc "Disconnects a contact from its login user (unlinks only; never deletes the user)."
  @spec disconnect_user(Contact.t()) :: {:ok, Contact.t()} | {:error, Ecto.Changeset.t()}
  def disconnect_user(%Contact{} = contact) do
    contact
    |> Contact.link_user_changeset(nil)
    |> repo().update()
  end

  @doc """
  Finds an existing user by email, or registers a placeholder with no usable
  password (tagged `custom_fields.source = "crm_contact"`).
  """
  @spec find_or_create_user_by_email(String.t()) ::
          {:ok, User.t(), :existing | :created} | {:error, atom() | Ecto.Changeset.t()}
  def find_or_create_user_by_email(email) when is_binary(email) do
    case String.trim(email) do
      "" -> {:error, :blank_email}
      trimmed -> find_or_register_placeholder(trimmed)
    end
  end

  defp find_or_register_placeholder(email) do
    case Auth.get_user_by_email(email) do
      %User{} = user -> {:ok, user, :existing}
      nil -> register_placeholder(email)
    end
  end

  defp register_placeholder(email) do
    attrs =
      %{"email" => email, "custom_fields" => %{"source" => @placeholder_source}}
      |> Map.put("password", Mirror.random_password())

    with {:ok, user} <- Auth.register_user(attrs), do: {:ok, user, :created}
  end

  # ── Explicit login-user connection (picker + "create mirror user") ──
  #
  # The opt-in checkbox above is find-or-create-by-email; these two are
  # the explicit mirror-panel actions (owner Q2: both stay, side by side).
  # Neither find-or-creates — `link_user/2` links a SPECIFIC, already-
  # chosen user, `create_mirror_user/1` always mints a fresh one.

  @doc """
  Links `contact` to an EXISTING person-`User` by uuid — no find-or-create
  (that's `connect_user/2`, above). Rejects a non-person-account user
  with `{:error, :not_a_person}` (an ALLOWLIST on `account_type ==
  "person"`, matching `Companies.connect_user/2`'s allowlist on
  `"organization"` exactly rather than a denylist on `"organization"` —
  today the two are equivalent since `person`/`organization` are the only
  values in use, but the allowlist doesn't silently accept a future third
  `account_type` the way a denylist would), and a missing user with
  `{:error, :user_not_found}`. A user already linked to another contact
  surfaces as `{:error, changeset}` via the partial unique index
  (`idx_crm_contacts_user_uuid`) rather than crashing. No-op-safe to call
  on an already-linked contact (re-links).
  """
  @spec link_user(Contact.t(), UUIDv7.t() | String.t()) ::
          {:ok, Contact.t()} | {:error, :not_a_person | :user_not_found | Ecto.Changeset.t()}
  def link_user(%Contact{} = contact, user_uuid) when is_binary(user_uuid) do
    case Auth.get_user(user_uuid) do
      nil ->
        {:error, :user_not_found}

      %User{account_type: "person"} ->
        link_and_log(contact, user_uuid)

      %User{} ->
        {:error, :not_a_person}
    end
  end

  defp link_and_log(%Contact{user_uuid: previous_user_uuid} = contact, user_uuid) do
    case contact |> Contact.link_user_changeset(user_uuid) |> repo().update() do
      {:ok, updated} = ok ->
        if previous_user_uuid != user_uuid do
          Logger.info("[CRM] contact #{updated.uuid} linked to user #{user_uuid}")
        end

        ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Creates a fresh person-`User` from `contact` (via `Mirror.attrs_from/2` —
  `account_type: "person"`, `first_name`/`last_name` split from
  `contact.name`, `email: contact.email`), tagged
  `custom_fields.source = "crm_contact"`, and links it — atomically: the
  created user is rolled back if the link fails.

  Rejects `{:error, :already_linked}` when `contact` already has a mirror
  user: without this guard a second call would silently mint and link a
  NEW user, orphaning the previous one (still present, an unrecoverable
  random password, linked to nothing).
  """
  @spec create_mirror_user(Contact.t()) ::
          {:ok, {Contact.t(), User.t()}} | {:error, :already_linked | term()}
  def create_mirror_user(%Contact{user_uuid: user_uuid}) when not is_nil(user_uuid) do
    {:error, :already_linked}
  end

  def create_mirror_user(%Contact{} = contact) do
    repo().transaction(fn ->
      attrs =
        :contact
        |> Mirror.attrs_from(contact)
        |> Map.put(:password, Mirror.random_password())
        |> Map.put(:custom_fields, %{"source" => @placeholder_source})
        |> Mirror.stringify_keys()

      with {:ok, user} <- Auth.register_user(attrs),
           {:ok, linked} <- link_user(contact, user.uuid) do
        {linked, user}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  @doc """
  The set of `user_uuid`s currently linked to any contact — used by the
  "Link existing…" picker (Task H) to exclude users who are already
  someone else's mirror.
  """
  @spec linked_user_uuids() :: MapSet.t()
  def linked_user_uuids do
    Contact
    |> where([c], not is_nil(c.user_uuid))
    |> select([c], c.user_uuid)
    |> repo().all()
    |> MapSet.new()
  end

  @doc """
  Applies a per-field conflict resolution — `PhoenixKitCRM.Mirror.resolve/4`'s
  `%{crm: crm_deltas, user: user_deltas}` — atomically: writes `crm_deltas`
  onto `contact`, `user_deltas` onto `user` (via `Auth.update_user_profile/2`,
  the same changeset core's own profile edits use), then links them. All
  three in one `repo().transaction/1` so a failure at any step leaves
  neither side partially rewritten.
  """
  @spec apply_mirror_resolution(Contact.t(), User.t(), %{crm: map(), user: map()}) ::
          {:ok, {Contact.t(), User.t()}} | {:error, term()}
  def apply_mirror_resolution(%Contact{} = contact, %User{} = user, %{
        crm: crm_deltas,
        user: user_deltas
      }) do
    repo().transaction(fn ->
      with {:ok, updated_contact} <- maybe_update_contact(contact, crm_deltas),
           {:ok, updated_user} <- maybe_update_user_profile(user, user_deltas),
           {:ok, linked} <- link_user(updated_contact, updated_user.uuid) do
        {linked, updated_user}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp maybe_update_contact(contact, deltas) when map_size(deltas) == 0, do: {:ok, contact}
  defp maybe_update_contact(contact, deltas), do: update_contact(contact, deltas)

  defp maybe_update_user_profile(user, deltas) when map_size(deltas) == 0, do: {:ok, user}
  defp maybe_update_user_profile(user, deltas), do: Auth.update_user_profile(user, deltas)

  # ── Helpers ─────────────────────────────────────────────────────────

  defp apply_status_scope(query, opts) do
    cond do
      opts[:status] -> where(query, [c], c.status == ^opts[:status])
      opts[:include_trashed] -> query
      true -> where(query, [c], c.status != "trashed")
    end
  end

  defp maybe_search_contacts(query, opts) do
    case Keyword.get(opts, :search) do
      term when is_binary(term) ->
        case String.trim(term) do
          "" ->
            query

          trimmed ->
            like = Search.like_pattern(trimmed)
            where(query, [c], ilike(c.name, ^like) or ilike(c.email, ^like))
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

  defp valid_uuid?(uuid), do: match?({:ok, _}, Ecto.UUID.cast(uuid))
end
