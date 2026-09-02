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

  # A role is in force when it is active AND today falls inside its validity
  # window. The dates used to be decorative — every query filtered on
  # `is_active` alone, so a role stamped with an expired `valid_to` still
  # resolved as a live supplier forever. Applied here so every caller agrees.
  defp in_force(query) do
    today = Date.utc_today()

    where(
      query,
      [pr],
      pr.is_active == true and
        (is_nil(pr.valid_from) or pr.valid_from <= ^today) and
        (is_nil(pr.valid_to) or pr.valid_to >= ^today)
    )
  end

  # ── Grant / revoke ──────────────────────────────────────────────────

  @doc """
  Grants `role` to a company or contact. Idempotent: granting a role that is
  currently IN FORCE is a no-op that returns the existing row unchanged —
  including any `attrs`, which are ignored on that path, so this is not a way
  to edit a live grant's window. Granting a previously-revoked role, or one
  whose `valid_to` has passed, starts a fresh tenure (`valid_from` today,
  `valid_to` cleared).

  `attrs` may set `:valid_from` / `:valid_to` and they win over those defaults
  on every path that writes, so a caller can still time-box a re-grant. A
  `valid_from` in the future is honoured as a scheduled grant: the row exists
  but no resolver reports the role until that date. Never pass caller-supplied
  `metadata` here from a UI path.

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
          attrs
          |> Map.merge(%{
            "roleable_type" => type,
            "roleable_uuid" => uuid,
            "role" => role
          })
          # `is_active` is this function's to decide, not the caller's: casting
          # a caller-supplied `is_active: false` would insert a dormant row and
          # then log it as granted. `valid_from`/`valid_to` stay caller-settable
          # as documented — an expired window is no longer dangerous now that
          # `in_force/1` makes every query respect it.
          |> Map.merge(%{"is_active" => true})
        )
        |> repo().insert()
        |> reconcile_grant_conflict(type, uuid, role)
        |> log_on_ok("crm.party_role_granted", type, uuid, opts)

      %PartyRole{is_active: true} = existing ->
        # `is_active` alone is not "holds the role": `in_force/1` also requires
        # today to fall inside the validity window. An active row whose
        # `valid_to` has passed resolves nowhere, so returning it unchanged
        # would report a grant that never took effect. Reopen it instead.
        if window_lapsed?(existing) do
          reopen(existing, attrs, type, uuid, opts)
        else
          {:ok, existing}
        end

      %PartyRole{is_active: false} = existing ->
        reopen(existing, attrs, type, uuid, opts)
    end
  end

  # Fresh tenure: keeping the ORIGINAL `valid_from` while clearing `valid_to`
  # would make the row assert an unbroken run from the first grant, erasing the
  # gap that actually happened. The per-period history lives in the activity
  # log, not in this row — the unique index means there can only ever be one.
  defp reopen(%PartyRole{} = existing, attrs, type, uuid, opts) do
    existing
    |> PartyRole.changeset(
      # The window is a DEFAULT here, not an override: merging the other way
      # round honoured `attrs` on the insert path and silently discarded it on
      # this one, so the same call time-boxed a fresh grant but produced an
      # open-ended one whenever a dormant row happened to exist. `is_active`
      # stays this function's to decide — see the insert branch.
      %{"valid_from" => Date.utc_today(), "valid_to" => nil}
      |> Map.merge(attrs)
      |> Map.put("is_active", true)
    )
    |> repo().update()
    |> log_on_ok("crm.party_role_granted", type, uuid, opts)
  end

  # Only a LAPSED window counts. A `valid_from` in the future is a scheduled
  # grant doing exactly what it was asked to do; dragging it forward to today
  # would silently cancel the schedule.
  defp window_lapsed?(%PartyRole{valid_to: nil}), do: false

  defp window_lapsed?(%PartyRole{valid_to: valid_to}),
    do: Date.compare(valid_to, Date.utc_today()) == :lt

  # Two concurrent grants both see `nil` and both insert; the unique index lets
  # one through and hands the other a changeset error. Since granting is
  # documented as idempotent, the loser should see the winner's row rather than
  # an error it did nothing to deserve.
  defp reconcile_grant_conflict(
         {:error, %Ecto.Changeset{errors: errors}} = error,
         type,
         uuid,
         role
       ) do
    # Ecto attaches a unique-constraint error to the FIRST field of the
    # `unique_constraint/3` declaration, so the two indexes surface on
    # different keys: the full one on `:roleable_type`, the V04 partial one
    # (`..._active_uniq`, declared `[:roleable_uuid, :role]`) on
    # `:roleable_uuid`. Which of the two Postgres reports is not ours to
    # choose — it follows index order, which a dump/restore can change — so
    # both keys have to be recognised or the race this exists for surfaces as
    # a raw changeset error on a restored database.
    if Enum.any?([:roleable_type, :roleable_uuid, :role], &Keyword.has_key?(errors, &1)) do
      case repo().get_by(PartyRole, roleable_type: type, roleable_uuid: uuid, role: role) do
        %PartyRole{} = winner -> {:ok, winner}
        nil -> error
      end
    else
      error
    end
  end

  defp reconcile_grant_conflict(result, _type, _uuid, _role), do: result

  @doc """
  Revokes `role` from a company or contact — sets `is_active` false and stamps
  `valid_to` with today's date. Never deletes the row.

  Note what "history" means here: the row records the CURRENT tenure, not every
  tenure. The unique index allows only one row per party and role, so a
  re-grant reuses it and stamps a fresh `valid_from`. The record of who
  granted and revoked what, and when, is the activity log.
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
    |> where([pr], pr.roleable_type == ^type and pr.roleable_uuid == ^uuid and pr.role == ^role)
    |> in_force()
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
  Active-role counts for one roleable type in a single grouped query, as a
  `%{role => count}` map covering every role in `PartyRole.roles/0` (zeros
  included, so a caller can render the full vocabulary without guessing).

  Each number matches the no-options `count_companies_with_role/2` /
  `count_contacts_with_role/2` for that role — in-force roles only, trashed
  holders excluded — so a count shown next to a link agrees with the filtered
  index the link opens.
  """
  @spec role_counts(String.t()) :: %{String.t() => non_neg_integer()}
  def role_counts("company"), do: role_counts_for(Company, "company")
  def role_counts("contact"), do: role_counts_for(Contact, "contact")

  defp role_counts_for(schema, type) do
    counted =
      PartyRole
      |> where([pr], pr.roleable_type == ^type)
      |> in_force()
      |> join(:inner, [pr], r in ^schema, on: r.uuid == pr.roleable_uuid)
      |> where([pr, r], r.status != "trashed")
      |> group_by([pr], pr.role)
      |> select([pr], {pr.role, count(pr.uuid)})
      |> repo().all()
      |> Map.new()

    Map.new(PartyRole.roles(), &{&1, Map.get(counted, &1, 0)})
  end

  @doc """
  Every party holding an active `role`, companies first then contacts, each
  normalized to the resolver's map shape (`:uuid`, `:name`, `:email`,
  `:phone`, `:website`, `:logo_url`, `:source`).

  `:source` is the specific `:crm_company` / `:crm_contact` tag rather than
  the generic `:crm` that `get_supplier/1` returns — callers persisting a
  source tag (the catalogue item form) need to know which side they picked.
  Takes the same options as `list_companies_with_role/2`.
  """
  @spec list_parties_with_role(String.t(), keyword()) :: [map()]
  def list_parties_with_role(role, opts \\ []) do
    # `:limit` bounds the COMBINED list. Passing it straight to both sides gave
    # a caller asking for 10 up to 20 rows.
    limit = Keyword.get(opts, :limit)
    side_opts = Keyword.delete(opts, :limit)

    companies =
      role
      |> list_companies_with_role(side_opts)
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: Company.display_name(c),
          email: c.email,
          phone: c.phone,
          website: c.website,
          logo_url: c.logo_url,
          source: :crm_company
        }
      end)

    contacts =
      role
      |> list_contacts_with_role(side_opts)
      |> Enum.map(fn c ->
        %{
          uuid: c.uuid,
          name: Contact.display_name(c),
          email: c.email,
          phone: c.phone,
          # Contacts carry no website or logo_url column.
          website: nil,
          logo_url: nil,
          source: :crm_contact
        }
      end)

    all = companies ++ contacts
    if limit, do: Enum.take(all, limit), else: all
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
  # roleable types (soft ref, audited), though since V04 the partial unique
  # index rules that out for ACTIVE rows. The tie-break below is byte-for-byte
  # the one in `active_role_row/2` — see the reasoning there — so the batch and
  # single paths cannot disagree about which side a uuid resolves on.
  defp active_role_rows(uuids, role) do
    PartyRole
    |> where([pr], pr.roleable_uuid in ^uuids and pr.role == ^role)
    |> in_force()
    # Same tie-break as `active_role_row/2` — the two must never disagree.
    |> order_by([pr],
      desc: fragment("? = 'company'", pr.roleable_type),
      asc: pr.inserted_at,
      asc: pr.uuid
    )
    |> select([pr], {pr.roleable_uuid, pr.roleable_type})
    |> repo().all()
    |> Enum.uniq_by(fn {uuid, _type} -> uuid end)
  end

  defp hydrate_companies([]), do: %{}

  defp hydrate_companies(uuids) do
    Company
    |> where([c], c.uuid in ^uuids and c.status != "trashed")
    |> repo().all()
    |> Map.new(fn c ->
      {c.uuid,
       %{
         uuid: c.uuid,
         name: Company.display_name(c),
         email: c.email,
         phone: c.phone,
         website: c.website,
         logo_url: c.logo_url,
         source: :crm
       }}
    end)
  end

  defp hydrate_contacts([]), do: %{}

  defp hydrate_contacts(uuids) do
    Contact
    |> where([c], c.uuid in ^uuids and c.status != "trashed")
    |> repo().all()
    |> Map.new(fn c ->
      {c.uuid,
       %{
         uuid: c.uuid,
         name: Contact.display_name(c),
         email: c.email,
         phone: c.phone,
         website: nil,
         logo_url: nil,
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
    |> where([pr], pr.roleable_type == ^type and pr.roleable_uuid in ^uuids)
    |> in_force()
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
      else: in_force(query)
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
  logo_url, source: :crm}` if that party currently has an *active* `supplier`
  role, or `nil` otherwise (unknown uuid, inactive role, or no supplier role
  at all).

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
            logo_url: String.t() | nil,
            source: :crm
          }
          | nil
  def get_supplier(uuid), do: get_party_with_role(uuid, "supplier")

  @doc """
  The `manufacturer`-role counterpart of `get_supplier/1`, with the identical
  return shape — the contract
  `PhoenixKitCatalogue.Catalogue.Manufacturers.resolve/1` calls.

  `logo_url` is what a company granted the `manufacturer` role carries as its
  brand mark now that manufacturers are managed here — see the V03 migration
  comment. Contacts have no `logo_url` column, so it resolves to `nil` there.

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
            logo_url: String.t() | nil,
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
    |> where([pr], pr.roleable_uuid == ^uuid and pr.role == ^role)
    |> in_force()
    # Company first, then oldest, then `uuid`. Since V04 the partial unique
    # index makes a second ACTIVE row for the same (uuid, role) impossible, so
    # the company key cannot actually fire today — it is here because it is the
    # side V04's dedupe keeps, and a resolver that preferred the other one
    # would contradict the migration the moment that index is ever relaxed.
    # `uuid` is the last key because timestamps are second-precision: two rows
    # inserted in the same second would otherwise let this and
    # `get_parties_with_role/2` disagree about which side a uuid resolves on.
    |> order_by([pr],
      desc: fragment("? = 'company'", pr.roleable_type),
      asc: pr.inserted_at,
      asc: pr.uuid
    )
    |> limit(1)
    |> repo().one()
  end

  # Trashed parties resolve to nothing, the same as they are excluded from
  # `list_companies_with_role/2`. Without this the two disagreed: trashing a
  # supplier removed it from the picker while item pages went on resolving it
  # as a live CRM supplier.
  defp hydrate_company_supplier(uuid) do
    case repo().get(Company, uuid) do
      %Company{status: "trashed"} ->
        nil

      %Company{} = c ->
        %{
          uuid: c.uuid,
          name: Company.display_name(c),
          email: c.email,
          phone: c.phone,
          website: c.website,
          logo_url: c.logo_url,
          source: :crm
        }

      nil ->
        nil
    end
  end

  defp hydrate_contact_supplier(uuid) do
    case repo().get(Contact, uuid) do
      %Contact{status: "trashed"} ->
        nil

      %Contact{} = c ->
        %{
          uuid: c.uuid,
          name: Contact.display_name(c),
          email: c.email,
          phone: c.phone,
          website: nil,
          logo_url: nil,
          source: :crm
        }

      nil ->
        nil
    end
  end

  @doc """
  Deletes every role row belonging to a party that is being permanently
  removed. Returns the number deleted.

  `roleable_uuid` is a soft reference with no foreign key, so nothing removes
  these rows on its own: a deleted company left its roles behind forever.
  They were invisible — the resolvers hydrate the party and get `nil` — but
  they accumulated, and counts and `list_roles/1` could still see them.
  """
  @spec delete_roles_for(String.t(), UUIDv7.t()) :: non_neg_integer()
  def delete_roles_for(type, uuid) when type in ~w(company contact) do
    {deleted, _} =
      PartyRole
      |> where([pr], pr.roleable_type == ^type and pr.roleable_uuid == ^uuid)
      |> repo().delete_all()

    deleted
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
