defmodule PhoenixKitCRM.Companies do
  @moduledoc """
  Context for CRM companies — CRUD, soft-delete, and search (for the contact
  form's company picker).
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Mirror
  alias PhoenixKitCRM.Schemas.{Company, CompanyMembership, Contact}
  alias PhoenixKitCRM.Search
  alias PhoenixKitCRM.SoftDelete

  defp repo, do: RepoHelper.repo()

  @placeholder_source "crm_company"

  @doc """
  Memberships at a company (primary first), each with its contact preloaded.
  Excludes memberships whose contact is trashed so soft-deleted people don't
  linger in the roster or the company's interactions rollup.
  """
  @spec list_memberships(UUIDv7.t() | String.t() | nil) :: [CompanyMembership.t()]
  def list_memberships(company_uuid) do
    case Ecto.UUID.cast(company_uuid) do
      {:ok, _} ->
        from(m in CompanyMembership,
          join: c in Contact,
          on: c.uuid == m.contact_uuid,
          where: m.company_uuid == ^company_uuid and c.status != "trashed",
          order_by: [desc: m.is_primary, asc: m.position]
        )
        |> repo().all()
        |> repo().preload(:contact)

      :error ->
        []
    end
  end

  @doc """
  Lists companies. Excludes trashed by default.

  ## Options
    * `:status` — `"trashed"` for the Trash view, or any specific status
    * `:include_trashed` — `true` to include trashed alongside the rest
    * `:search` — name/email ILIKE match
    * `:limit` / `:offset` — pagination; both no-ops when absent
  """
  @spec list_companies(keyword()) :: [Company.t()]
  def list_companies(opts \\ []) do
    Company
    |> apply_status_scope(opts)
    |> maybe_search_companies(opts)
    |> order_by([c], asc: c.name)
    |> maybe_paginate(opts)
    |> repo().all()
  end

  @doc """
  Live-untrashed companies as `%{value: uuid, label: name}` picker options.

  The lazy option source behind the projects hub's Client extension
  `config_schema` select (`{PhoenixKitCRM.Companies, :company_options}`) —
  so linking a client is picking a name, not pasting a uuid. Capped: the
  hub always re-adds the STORED value even when it isn't offered, so a
  large install degrades to "the current link still shows" rather than an
  unbounded select. Degrades to `[]` when the DB is unreachable — the
  panel must render even with CRM's storage down.
  """
  @spec company_options() :: [%{value: String.t(), label: String.t()}]
  def company_options do
    [limit: 500]
    |> list_companies()
    |> Enum.map(&%{value: &1.uuid, label: &1.name})
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Companies for the given uuids (any status) — for comment back-link resolution."
  @spec list_by_uuids([binary()]) :: [Company.t()]
  def list_by_uuids([]), do: []

  def list_by_uuids(uuids) when is_list(uuids) do
    # Drop malformed ids so one bad element can't raise an Ecto cast error.
    case Enum.filter(uuids, &valid_uuid?/1) do
      [] -> []
      valid -> from(c in Company, where: c.uuid in ^valid) |> repo().all()
    end
  end

  @doc "Same filters as `list_companies/1` (`:status`/`:include_trashed`/`:search`); ignores `:limit`/`:offset`."
  @spec count_companies(keyword()) :: non_neg_integer()
  def count_companies(opts \\ []) do
    Company
    |> apply_status_scope(opts)
    |> maybe_search_companies(opts)
    |> repo().aggregate(:count, :uuid)
  end

  @spec get_company(UUIDv7.t() | String.t() | nil) :: Company.t() | nil
  def get_company(uuid) do
    # Format-check first so a malformed id returns nil instead of raising.
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> repo().get(Company, uuid)
      :error -> nil
    end
  end

  @spec change_company(Company.t(), map()) :: Ecto.Changeset.t()
  def change_company(%Company{} = company, attrs \\ %{}),
    do: Company.changeset(company, attrs)

  @spec create_company(map()) :: {:ok, Company.t()} | {:error, Ecto.Changeset.t()}
  def create_company(attrs) do
    %Company{}
    |> Company.changeset(attrs)
    |> repo().insert()
  end

  @spec update_company(Company.t(), map()) :: {:ok, Company.t()} | {:error, Ecto.Changeset.t()}
  def update_company(%Company{} = company, attrs) do
    company
    |> Company.changeset(attrs)
    |> repo().update()
  end

  @doc "Soft-deletes a company (status → trashed, stashing the prior status)."
  @spec trash_company(Company.t()) :: {:ok, Company.t()} | {:error, atom() | Ecto.Changeset.t()}
  def trash_company(%Company{status: "trashed"}), do: {:error, :already_trashed}

  def trash_company(%Company{} = company) do
    company
    |> SoftDelete.trash_changeset(Company.soft_delete_status())
    |> repo().update()
  end

  @spec restore_company(Company.t()) :: {:ok, Company.t()} | {:error, atom() | Ecto.Changeset.t()}
  def restore_company(%Company{status: "trashed"} = company) do
    company
    |> SoftDelete.restore_changeset(Company.statuses())
    |> repo().update()
  end

  def restore_company(%Company{}), do: {:error, :not_trashed}

  @doc "Permanently deletes a company (cascades its memberships)."
  @spec delete_company(Company.t()) :: {:ok, Company.t()} | {:error, Ecto.Changeset.t()}
  def delete_company(%Company{} = company), do: repo().delete(company)

  @doc "Searches companies by name (case-insensitive) for the picker. Excludes trashed."
  @spec search_companies(String.t(), pos_integer()) :: [Company.t()]
  def search_companies(query, limit \\ 8) when is_binary(query) do
    q = query |> String.replace("\x00", "") |> String.trim()

    if q == "" do
      []
    else
      like = Search.like_pattern(q)

      Company
      |> where([c], c.status != "trashed")
      |> where([c], ilike(c.name, ^like))
      |> order_by([c], asc: c.name)
      |> limit(^limit)
      |> repo().all()
    end
  end

  # ── Optional organization-user mirror connection (Q3) ────────────────
  #
  # A Company mirrors ONLY to an `account_type: "organization"` User — no
  # membership/organization_uuid propagation. `Company.user_uuid` is a
  # nullable FK (ON DELETE SET NULL, partial unique index
  # idx_crm_companies_user_uuid) — mirrors `Contacts`' user connection,
  # just without the find-or-create-by-email shortcut (Company has no
  # implicit "log in" checkbox; every link here is explicit).

  @doc "The (at most one) company linked to a given login user, or nil."
  @spec get_by_user_uuid(UUIDv7.t() | String.t() | nil) :: Company.t() | nil
  def get_by_user_uuid(nil), do: nil

  def get_by_user_uuid(user_uuid) do
    # Format-check first so a malformed id returns nil instead of raising.
    case Ecto.UUID.cast(user_uuid) do
      {:ok, _} -> repo().get_by(Company, user_uuid: user_uuid)
      :error -> nil
    end
  end

  @doc """
  `%{user_uuid => company}` for the given login users — the batched form
  of `get_by_user_uuid/1` (mirrors `Contacts.map_by_user_uuids/1`), for
  table views (Task I's Organizations list) that would otherwise query
  once per row. Users with no linked company are absent from the map.
  """
  @spec map_by_user_uuids([UUIDv7.t() | String.t()]) :: %{optional(String.t()) => Company.t()}
  def map_by_user_uuids([]), do: %{}

  def map_by_user_uuids(user_uuids) when is_list(user_uuids) do
    case Enum.filter(user_uuids, &valid_uuid?/1) do
      [] ->
        %{}

      valid ->
        from(c in Company, where: c.user_uuid in ^valid)
        |> repo().all()
        |> Map.new(&{&1.user_uuid, &1})
    end
  end

  @doc """
  Non-trashed companies with no mirror user linked — the candidate set
  for the "Link existing company…" picker (Task I, reverse direction:
  an organization-user picking a company to adopt).
  """
  @spec list_unlinked_companies() :: [Company.t()]
  def list_unlinked_companies do
    Company
    |> where([c], is_nil(c.user_uuid) and c.status != "trashed")
    |> order_by([c], asc: c.name)
    |> repo().all()
  end

  @doc """
  Links `company` to an EXISTING organization-`User` by uuid. Rejects a
  user that isn't `account_type: "organization"` (Q3) with
  `{:error, :not_an_organization}`, and a missing user with
  `{:error, :user_not_found}`. A user already linked to another company
  surfaces as `{:error, changeset}` via the partial unique index
  (`idx_crm_companies_user_uuid`) rather than crashing. No-op-safe to call
  on an already-linked company (re-links).
  """
  @spec connect_user(Company.t(), UUIDv7.t() | String.t()) ::
          {:ok, Company.t()}
          | {:error, :not_an_organization | :user_not_found | Ecto.Changeset.t()}
  def connect_user(%Company{} = company, user_uuid) when is_binary(user_uuid) do
    case Auth.get_user(user_uuid) do
      nil ->
        {:error, :user_not_found}

      %User{account_type: "organization"} ->
        link_and_log(company, user_uuid)

      %User{} ->
        {:error, :not_an_organization}
    end
  end

  defp link_and_log(%Company{user_uuid: previous_user_uuid} = company, user_uuid) do
    case company |> Company.link_user_changeset(user_uuid) |> repo().update() do
      {:ok, updated} = ok ->
        if previous_user_uuid != user_uuid do
          Logger.info("[CRM] company #{updated.uuid} linked to user #{user_uuid}")
        end

        ok

      {:error, _} = err ->
        err
    end
  end

  @doc "Disconnects `company` from its mirror user (unlinks only; never deletes the user)."
  @spec disconnect_user(Company.t()) :: {:ok, Company.t()} | {:error, Ecto.Changeset.t()}
  def disconnect_user(%Company{user_uuid: previous_user_uuid} = company) do
    case company |> Company.link_user_changeset(nil) |> repo().update() do
      {:ok, updated} = ok ->
        if previous_user_uuid do
          Logger.info(
            "[CRM] company #{updated.uuid} disconnected from user #{previous_user_uuid}"
          )
        end

        ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Creates a fresh organization-`User` from `company` (via
  `Mirror.attrs_from/2` — `account_type: "organization"`,
  `organization_name: company.name`, `email: company.email`), tagged
  `custom_fields.source = "crm_company"`, and links it — atomically: the
  created user is rolled back if the link fails (a validation error, a
  race — anything).

  Rejects `{:error, :already_linked}` when `company` already has a mirror
  user: without this guard a second call would silently mint and link a
  NEW user, orphaning the previous one (still present, still an
  organization account with an unrecoverable random password, linked to
  nothing). `disconnect_user/1` first, then `create_mirror_user/2` again,
  if that's genuinely what's wanted.

  `opts` is currently unused — reserved for a future extension point
  (e.g. actor attribution for the log line), kept in the signature so
  adding one later isn't a breaking change.
  """
  @spec create_mirror_user(Company.t(), keyword()) ::
          {:ok, {Company.t(), User.t()}} | {:error, :already_linked | term()}
  def create_mirror_user(company, opts \\ [])

  def create_mirror_user(%Company{user_uuid: user_uuid}, _opts) when not is_nil(user_uuid) do
    {:error, :already_linked}
  end

  def create_mirror_user(%Company{} = company, _opts) do
    repo().transaction(fn ->
      attrs =
        :company
        |> Mirror.attrs_from(company)
        |> Map.put(:password, random_password())
        |> Map.put(:custom_fields, %{"source" => @placeholder_source})
        |> stringify_keys()

      with {:ok, user} <- Auth.register_user(attrs),
           {:ok, linked} <- connect_user(company, user.uuid) do
        {linked, user}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  @doc """
  Reverse of `create_mirror_user/2`: given an organization-`User`, adopts
  an existing UNLINKED company (matched by name first, then email —
  mirrors `Andi.CRMBridge`'s adopt-by-email precedent for contacts) or
  creates a new one from `Mirror.attrs_to_crm/2`, then links it — the
  create-then-link is wrapped in one transaction, so a `connect_user/2`
  failure (a race against a concurrent caller linking the same user
  first, most plausibly) rolls back the just-created company rather than
  leaving an orphaned, unlinked row behind.

  Rejects `{:error, {:already_linked, existing}}` when `user` already has
  a mirror company (checked up front, before touching anything) and
  `{:error, :not_an_organization}` for a non-organization user.
  """
  @spec create_from_user(User.t()) ::
          {:ok, Company.t()}
          | {:error, {:already_linked, Company.t()} | :not_an_organization | term()}
  def create_from_user(%User{account_type: "organization"} = user) do
    case get_by_user_uuid(user.uuid) do
      %Company{} = existing ->
        {:error, {:already_linked, existing}}

      nil ->
        repo().transaction(fn ->
          case link_or_create(user) do
            {:ok, linked} -> linked
            {:error, reason} -> repo().rollback(reason)
          end
        end)
    end
  end

  def create_from_user(%User{}), do: {:error, :not_an_organization}

  defp link_or_create(user) do
    case adoptable_company_for(user) do
      %Company{} = company ->
        connect_user(company, user.uuid)

      nil ->
        with {:ok, company} <- create_company(stringify_keys(Mirror.attrs_to_crm(:company, user))) do
          connect_user(company, user.uuid)
        end
    end
  end

  defp adoptable_company_for(user) do
    adoptable_company_by_name(user.organization_name) ||
      adoptable_company_by_email(user.email)
  end

  defp adoptable_company_by_name(name) when is_binary(name) and name != "" do
    Company
    |> where([c], c.name == ^name and c.status != "trashed" and is_nil(c.user_uuid))
    |> order_by([c], asc: c.inserted_at)
    |> limit(1)
    |> repo().one()
  end

  defp adoptable_company_by_name(_), do: nil

  defp adoptable_company_by_email(email) when is_binary(email) and email != "" do
    Company
    |> where([c], c.email == ^email and c.status != "trashed" and is_nil(c.user_uuid))
    |> order_by([c], asc: c.inserted_at)
    |> limit(1)
    |> repo().one()
  end

  defp adoptable_company_by_email(_), do: nil

  @doc """
  The set of `user_uuid`s currently linked to any company — used by the
  "Link existing…" picker (Task G) to exclude users who are already
  someone else's mirror.
  """
  @spec linked_user_uuids() :: MapSet.t()
  def linked_user_uuids do
    Company
    |> where([c], not is_nil(c.user_uuid))
    |> select([c], c.user_uuid)
    |> repo().all()
    |> MapSet.new()
  end

  @doc """
  Applies a per-field conflict resolution — `PhoenixKitCRM.Mirror.resolve/4`'s
  `%{crm: crm_deltas, user: user_deltas}` — atomically: writes `crm_deltas`
  onto `company`, `user_deltas` onto `user` (via `Auth.update_user_profile/2`,
  the same changeset core's own profile edits use), then links them. All
  three in one `repo().transaction/1` so a failure at any step leaves
  neither side partially rewritten.
  """
  @spec apply_mirror_resolution(Company.t(), User.t(), %{crm: map(), user: map()}) ::
          {:ok, {Company.t(), User.t()}} | {:error, term()}
  def apply_mirror_resolution(%Company{} = company, %User{} = user, %{
        crm: crm_deltas,
        user: user_deltas
      }) do
    repo().transaction(fn ->
      with {:ok, updated_company} <- maybe_update_company(company, crm_deltas),
           {:ok, updated_user} <- maybe_update_user_profile(user, user_deltas),
           {:ok, linked} <- connect_user(updated_company, updated_user.uuid) do
        {linked, updated_user}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp maybe_update_company(company, deltas) when map_size(deltas) == 0, do: {:ok, company}
  defp maybe_update_company(company, deltas), do: update_company(company, deltas)

  defp maybe_update_user_profile(user, deltas) when map_size(deltas) == 0, do: {:ok, user}
  defp maybe_update_user_profile(user, deltas), do: Auth.update_user_profile(user, deltas)

  defp random_password do
    random = :crypto.strong_rand_bytes(24) |> Base.url_encode64() |> binary_part(0, 24)
    random <> "Aa1!"
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  defp maybe_search_companies(query, opts) do
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

  defp apply_status_scope(query, opts) do
    cond do
      opts[:status] -> where(query, [c], c.status == ^opts[:status])
      opts[:include_trashed] -> query
      true -> where(query, [c], c.status != "trashed")
    end
  end

  defp valid_uuid?(uuid), do: match?({:ok, _}, Ecto.UUID.cast(uuid))
end
