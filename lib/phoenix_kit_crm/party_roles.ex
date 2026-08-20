defmodule PhoenixKitCRM.PartyRoles do
  @moduledoc """
  Context for CRM party roles — marks an existing company or contact as a
  `supplier`, `customer`, or `partner` (see `PhoenixKitCRM.Schemas.PartyRole`).

  Mutations are logged here (not in the LiveViews) because `grant_role/3`
  and `revoke_role/2` are called from both the company form and the contact
  form's Roles section — a single log point keeps the audit trail consistent
  regardless of caller, mirroring `PhoenixKitCRM.Interactions`. There is no
  live-updating tab for roles yet, so unlike interactions this context does
  not broadcast over PubSub.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.Activity
  alias PhoenixKitCRM.Schemas.{Company, Contact, PartyRole}
  alias PhoenixKitCRM.Search

  defp repo, do: RepoHelper.repo()

  # ── Grant / revoke ──────────────────────────────────────────────────

  @doc """
  Grants `role` to a company or contact. Idempotent: granting an already-active
  role is a no-op (returns the existing row); granting a previously-revoked
  role reactivates it (clears `valid_to`). `attrs` may set `:valid_from` /
  `:valid_to` — never pass caller-supplied `metadata` here from a UI path.

  Pass `:actor_uuid` in `opts` so the activity log entry records who granted
  the role (mirrors every other logged CRM mutation).
  """
  @spec grant_role(Company.t() | Contact.t(), String.t(), map(), keyword()) ::
          {:ok, PartyRole.t()} | {:error, Ecto.Changeset.t()}
  def grant_role(roleable, role, attrs \\ %{}, opts \\ []) do
    type = roleable_type(roleable)
    uuid = roleable.uuid
    attrs = stringify_keys(attrs)

    case repo().get_by(PartyRole, roleable_type: type, roleable_uuid: uuid, role: role) do
      nil ->
        %PartyRole{}
        |> PartyRole.changeset(
          Map.merge(attrs, %{
            "roleable_type" => type,
            "roleable_uuid" => uuid,
            "role" => role
          })
        )
        |> repo().insert()
        |> log_on_ok("crm.party_role_granted", type, uuid, opts)

      %PartyRole{is_active: true} = existing ->
        {:ok, existing}

      %PartyRole{is_active: false} = existing ->
        existing
        |> PartyRole.changeset(Map.merge(attrs, %{"is_active" => true, "valid_to" => nil}))
        |> repo().update()
        |> log_on_ok("crm.party_role_granted", type, uuid, opts)
    end
  end

  @doc """
  Revokes `role` from a company or contact — sets `is_active` false and stamps
  `valid_to` with today's date. Never deletes the row (role history is kept).
  A no-op if the role isn't currently held (returns `{:error, :not_found}`) or
  is already inactive.

  Pass `:actor_uuid` in `opts` so the activity log entry records who revoked
  the role (mirrors every other logged CRM mutation).
  """
  @spec revoke_role(Company.t() | Contact.t(), String.t(), keyword()) ::
          {:ok, PartyRole.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_role(roleable, role, opts \\ []) do
    type = roleable_type(roleable)
    uuid = roleable.uuid

    case repo().get_by(PartyRole, roleable_type: type, roleable_uuid: uuid, role: role) do
      nil ->
        {:error, :not_found}

      %PartyRole{is_active: false} = existing ->
        {:ok, existing}

      %PartyRole{} = existing ->
        existing
        |> PartyRole.lifecycle_changeset(%{"is_active" => false, "valid_to" => Date.utc_today()})
        |> repo().update()
        |> log_on_ok("crm.party_role_revoked", type, uuid, opts)
    end
  end

  defp log_on_ok(
         {:ok, %PartyRole{} = party_role} = ok,
         action,
         roleable_type,
         roleable_uuid,
         opts
       ) do
    Activity.log(action,
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: resource_type(roleable_type),
      resource_uuid: roleable_uuid,
      metadata: %{"role" => party_role.role, "roleable_type" => roleable_type}
    )

    ok
  end

  defp log_on_ok(error, _action, _type, _uuid, _opts), do: error

  defp resource_type("company"), do: "crm_company"
  defp resource_type("contact"), do: "crm_contact"

  # ── Queries ─────────────────────────────────────────────────────────

  @doc "Whether the company/contact currently has an active `role`."
  @spec has_role?(Company.t() | Contact.t(), String.t()) :: boolean()
  def has_role?(roleable, role) do
    type = roleable_type(roleable)
    uuid = roleable.uuid

    PartyRole
    |> where(
      [pr],
      pr.roleable_type == ^type and pr.roleable_uuid == ^uuid and pr.role == ^role and
        pr.is_active == true
    )
    |> repo().exists?()
  end

  @doc "All role rows (active and inactive) held by a company/contact, role ascending."
  @spec list_roles(Company.t() | Contact.t()) :: [PartyRole.t()]
  def list_roles(roleable) do
    type = roleable_type(roleable)
    uuid = roleable.uuid

    PartyRole
    |> where([pr], pr.roleable_type == ^type and pr.roleable_uuid == ^uuid)
    |> order_by([pr], asc: pr.role)
    |> repo().all()
  end

  @doc """
  Companies holding an active `role`, name ascending. Excludes trashed
  companies by default.

  ## Options
    * `:include_inactive` — include revoked role rows too
    * `:include_trashed` — include trashed companies too
    * `:search` — name/email ILIKE match
    * `:limit` / `:offset` — pagination; no-ops when absent
  """
  @spec list_companies_with_role(String.t(), keyword()) :: [Company.t()]
  def list_companies_with_role(role, opts \\ []) do
    uuids = roleable_uuids("company", role, opts)

    Company
    |> where([c], c.uuid in ^uuids)
    |> maybe_exclude_trashed(opts)
    |> maybe_search_roleable(opts)
    |> order_by([c], asc: c.name)
    |> maybe_paginate(opts)
    |> repo().all()
  end

  @doc "Same filters as `list_companies_with_role/2`, minus `:limit`/`:offset`."
  @spec count_companies_with_role(String.t(), keyword()) :: non_neg_integer()
  def count_companies_with_role(role, opts \\ []) do
    uuids = roleable_uuids("company", role, opts)

    Company
    |> where([c], c.uuid in ^uuids)
    |> maybe_exclude_trashed(opts)
    |> maybe_search_roleable(opts)
    |> repo().aggregate(:count, :uuid)
  end

  @doc "Contacts holding an active `role`, name ascending. Same options as `list_companies_with_role/2`."
  @spec list_contacts_with_role(String.t(), keyword()) :: [Contact.t()]
  def list_contacts_with_role(role, opts \\ []) do
    uuids = roleable_uuids("contact", role, opts)

    Contact
    |> where([c], c.uuid in ^uuids)
    |> maybe_exclude_trashed(opts)
    |> maybe_search_roleable(opts)
    |> order_by([c], asc: c.name)
    |> maybe_paginate(opts)
    |> repo().all()
  end

  @doc "Same filters as `list_contacts_with_role/2`, minus `:limit`/`:offset`."
  @spec count_contacts_with_role(String.t(), keyword()) :: non_neg_integer()
  def count_contacts_with_role(role, opts \\ []) do
    uuids = roleable_uuids("contact", role, opts)

    Contact
    |> where([c], c.uuid in ^uuids)
    |> maybe_exclude_trashed(opts)
    |> maybe_search_roleable(opts)
    |> repo().aggregate(:count, :uuid)
  end

  @doc """
  Every party holding an active `role`, companies first then contacts, each
  normalized to the resolver's map shape (`:uuid`, `:name`, `:email`,
  `:phone`, `:website`, `:source`).

  `:source` is the specific `:crm_company` / `:crm_contact` tag rather than
  the generic `:crm` that `get_supplier/1` returns — callers persisting a
  source tag (the catalogue item form) need to know which side they picked.
  Takes the same options as `list_companies_with_role/2`.
  """
  @spec list_parties_with_role(String.t(), keyword()) :: [map()]
  def list_parties_with_role(role, opts \\ []) do
    companies =
      role
      |> list_companies_with_role(opts)
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: Company.display_name(c),
          email: c.email,
          phone: c.phone,
          website: c.website,
          source: :crm_company
        }
      end)

    contacts =
      role
      |> list_contacts_with_role(opts)
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: Contact.display_name(c),
          email: c.email,
          phone: c.phone,
          # Contacts carry no website column.
          website: nil,
          source: :crm_contact
        }
      end)

    companies ++ contacts
  end

  @doc """
  Batch counterpart of `get_supplier/1` / `get_manufacturer/1`: resolves many
  party uuids holding an active `role` in ONE pair of queries, returning
  `%{uuid => party_map}`. Uuids with no active role for `role` are absent.

  This is the function a catalogue page renders 100 items through — resolving
  them one at a time across the module boundary is the N+1 this exists to
  prevent. Malformed uuids are dropped rather than raising, because the caller
  is feeding in soft cross-module references that nothing constrains.
  """
  @spec get_parties_with_role([UUIDv7.t() | String.t()], String.t()) :: %{UUIDv7.t() => map()}
  def get_parties_with_role([], _role), do: %{}

  def get_parties_with_role(uuids, role) when is_list(uuids) do
    uuids = valid_uuids(uuids)

    if uuids == [] do
      %{}
    else
      roles = active_role_rows(uuids, role)

      company_uuids = for {uuid, "company"} <- roles, do: uuid
      contact_uuids = for {uuid, "contact"} <- roles, do: uuid

      Map.merge(hydrate_companies(company_uuids), hydrate_contacts(contact_uuids))
    end
  end

  @doc "Batch `supplier` resolution. See `get_parties_with_role/2`."
  @spec get_suppliers([UUIDv7.t() | String.t()]) :: %{UUIDv7.t() => map()}
  def get_suppliers(uuids), do: get_parties_with_role(uuids, "supplier")

  @doc "Batch `manufacturer` resolution. See `get_parties_with_role/2`."
  @spec get_manufacturers([UUIDv7.t() | String.t()]) :: %{UUIDv7.t() => map()}
  def get_manufacturers(uuids), do: get_parties_with_role(uuids, "manufacturer")

  defp valid_uuids(uuids) do
    uuids
    |> Enum.flat_map(fn uuid ->
      case Ecto.UUID.cast(uuid) do
        {:ok, _} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  # One row per uuid: the same uuid could in principle carry the role under both
  # roleable types (soft ref, audited). Company wins deterministically, matching
  # `get_party_with_role/2`'s oldest-first single pick closely enough that the
  # batch and single paths cannot disagree about which side a uuid resolves on.
  defp active_role_rows(uuids, role) do
    PartyRole
    |> where([pr], pr.roleable_uuid in ^uuids and pr.role == ^role and pr.is_active == true)
    |> order_by([pr], asc: pr.inserted_at)
    |> select([pr], {pr.roleable_uuid, pr.roleable_type})
    |> repo().all()
    |> Enum.uniq_by(fn {uuid, _type} -> uuid end)
  end

  defp hydrate_companies([]), do: %{}

  defp hydrate_companies(uuids) do
    Company
    |> where([c], c.uuid in ^uuids)
    |> repo().all()
    |> Map.new(fn c ->
      {c.uuid,
       %{
         uuid: c.uuid,
         name: Company.display_name(c),
         email: c.email,
         phone: c.phone,
         website: c.website,
         source: :crm
       }}
    end)
  end

  defp hydrate_contacts([]), do: %{}

  defp hydrate_contacts(uuids) do
    Contact
    |> where([c], c.uuid in ^uuids)
    |> repo().all()
    |> Map.new(fn c ->
      {c.uuid,
       %{
         uuid: c.uuid,
         name: Contact.display_name(c),
         email: c.email,
         phone: c.phone,
         website: nil,
         source: :crm
       }}
    end)
  end

  @doc "Parties holding an active `supplier` role. See `list_parties_with_role/2`."
  @spec list_suppliers(keyword()) :: [map()]
  def list_suppliers(opts \\ []), do: list_parties_with_role("supplier", opts)

  @doc "Parties holding an active `manufacturer` role. See `list_parties_with_role/2`."
  @spec list_manufacturers(keyword()) :: [map()]
  def list_manufacturers(opts \\ []), do: list_parties_with_role("manufacturer", opts)

  @doc "Parties holding an active `customer` role. See `list_parties_with_role/2`."
  @spec list_customers(keyword()) :: [map()]
  def list_customers(opts \\ []), do: list_parties_with_role("customer", opts)

  @doc """
  Active roles for a batch of companies/contacts in one query — for role
  badges on list pages. Returns `%{roleable_uuid => [role, ...]}` (uuids
  with no active roles are absent).
  """
  @spec active_roles_map(String.t(), [UUIDv7.t()]) :: %{UUIDv7.t() => [String.t()]}
  def active_roles_map(_type, []), do: %{}

  def active_roles_map(type, uuids) when is_list(uuids) do
    PartyRole
    |> where(
      [pr],
      pr.roleable_type == ^type and pr.roleable_uuid in ^uuids and pr.is_active == true
    )
    |> select([pr], {pr.roleable_uuid, pr.role})
    |> repo().all()
    |> Enum.group_by(fn {uuid, _} -> uuid end, fn {_, role} -> role end)
  end

  defp roleable_uuids(type, role, opts) do
    PartyRole
    |> where([pr], pr.roleable_type == ^type and pr.role == ^role)
    |> maybe_active_scope(opts)
    |> select([pr], pr.roleable_uuid)
    |> repo().all()
  end

  defp maybe_active_scope(query, opts) do
    if Keyword.get(opts, :include_inactive, false),
      do: query,
      else: where(query, [pr], pr.is_active == true)
  end

  defp maybe_exclude_trashed(query, opts) do
    if Keyword.get(opts, :include_trashed, false),
      do: query,
      else: where(query, [c], c.status != "trashed")
  end

  # Same `name`/`email` shape on both Company and Contact, so one clause
  # covers `list_companies_with_role/2` and `list_contacts_with_role/2`.
  defp maybe_search_roleable(query, opts) do
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

  @doc """
  Resolver entry point for the (future) Catalogue supplier facade: given a
  company **or** contact uuid, returns `%{uuid, name, email, phone, website,
  source: :crm}` if that party currently has an *active* `supplier` role, or
  `nil` otherwise (unknown uuid, inactive role, or no supplier role at all).

  This is the contract `PhoenixKitCatalogue.Catalogue.Suppliers.resolve/1`
  will call in Phase 2 (see the CRM v2 parties design doc, §4.3) — keep the
  return shape stable.
  """
  @spec get_supplier(UUIDv7.t() | String.t() | nil) ::
          %{
            uuid: UUIDv7.t(),
            name: String.t(),
            email: String.t() | nil,
            phone: String.t() | nil,
            website: String.t() | nil,
            source: :crm
          }
          | nil
  def get_supplier(uuid), do: get_party_with_role(uuid, "supplier")

  @doc """
  The `manufacturer`-role counterpart of `get_supplier/1`, with the identical
  return shape — the contract
  `PhoenixKitCatalogue.Catalogue.Manufacturers.resolve/1` calls.

  Note what this does NOT mean: catalogue items still reference the local
  `phoenix_kit_cat_manufacturers` row through a hard FK. This resolver
  federates the manufacturer *directory* and pickers, not item references.
  """
  @spec get_manufacturer(UUIDv7.t() | String.t() | nil) ::
          %{
            uuid: UUIDv7.t(),
            name: String.t(),
            email: String.t() | nil,
            phone: String.t() | nil,
            website: String.t() | nil,
            source: :crm
          }
          | nil
  def get_manufacturer(uuid), do: get_party_with_role(uuid, "manufacturer")

  defp get_party_with_role(uuid, role) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} ->
        case active_role_row(uuid, role) do
          %PartyRole{roleable_type: "company"} -> hydrate_company_supplier(uuid)
          %PartyRole{roleable_type: "contact"} -> hydrate_contact_supplier(uuid)
          nil -> nil
        end

      :error ->
        nil
    end
  end

  defp active_role_row(uuid, role) do
    # limit(1): a boundary resolver federating two modules must not raise on a
    # dirty soft-ref. The unique index is per (roleable_type, roleable_uuid,
    # role), so the same uuid could in principle hold an active row for this
    # role under both types (audited soft-ref risk); take one deterministically
    # rather than let repo().one() raise Ecto.MultipleResultsError.
    PartyRole
    |> where([pr], pr.roleable_uuid == ^uuid and pr.role == ^role and pr.is_active == true)
    |> order_by([pr], asc: pr.inserted_at)
    |> limit(1)
    |> repo().one()
  end

  defp hydrate_company_supplier(uuid) do
    case repo().get(Company, uuid) do
      %Company{} = c ->
        %{
          uuid: c.uuid,
          name: Company.display_name(c),
          email: c.email,
          phone: c.phone,
          website: c.website,
          source: :crm
        }

      nil ->
        nil
    end
  end

  defp hydrate_contact_supplier(uuid) do
    case repo().get(Contact, uuid) do
      %Contact{} = c ->
        %{
          uuid: c.uuid,
          name: Contact.display_name(c),
          email: c.email,
          phone: c.phone,
          website: nil,
          source: :crm
        }

      nil ->
        nil
    end
  end

  # ── Legacy data ─────────────────────────────────────────────────────

  @legacy_role "client"
  @renamed_role "customer"

  @doc """
  One-time normalization of legacy `"client"` party-role rows to `"customer"`.

  0.2.x shipped `supplier`/`client`/`partner`; the role was renamed to
  `customer` after that, and nothing rewrote the rows already in a host's
  database. A stranded `"client"` row is not visible under the Customers
  filter (which queries `"customer"`), has no checkbox on the company/contact
  form (`PartyRole.roles/0` no longer lists it, so `sync_roles/3` never
  touches it) and renders as a raw grey badge. Run this once per database on
  upgrade — see `mix phoenix_kit_crm.rename_client_role`.

  A party that already holds `"customer"` would collide with the
  `(roleable_type, roleable_uuid, role)` unique index, so its legacy row is
  dropped instead of renamed: the newer row is the authoritative one. Both
  steps run in one transaction, and the whole thing is idempotent — a second
  run reports `%{renamed: 0, dropped: 0}`.
  """
  @spec rename_legacy_client_roles() :: %{renamed: non_neg_integer(), dropped: non_neg_integer()}
  def rename_legacy_client_roles do
    {:ok, result} =
      repo().transaction(fn ->
        {dropped, _} =
          PartyRole
          |> from(as: :legacy)
          |> where([legacy: p], p.role == ^@legacy_role)
          |> where(
            [legacy: p],
            exists(
              from(c in PartyRole,
                where: c.role == ^@renamed_role,
                where: c.roleable_type == parent_as(:legacy).roleable_type,
                where: c.roleable_uuid == parent_as(:legacy).roleable_uuid,
                select: 1
              )
            )
          )
          |> repo().delete_all()

        {renamed, _} =
          PartyRole
          |> where([p], p.role == ^@legacy_role)
          |> repo().update_all(
            set: [
              role: @renamed_role,
              updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            ]
          )

        %{renamed: renamed, dropped: dropped}
      end)

    result
  end

  @doc "How many legacy `\"client\"` party-role rows are still present."
  @spec count_legacy_client_roles() :: non_neg_integer()
  def count_legacy_client_roles do
    PartyRole
    |> where([p], p.role == ^@legacy_role)
    |> repo().aggregate(:count, :uuid)
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp roleable_type(%Company{}), do: "company"
  defp roleable_type(%Contact{}), do: "contact"

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
