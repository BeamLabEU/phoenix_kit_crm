defmodule PhoenixKitCRM.Companies do
  @moduledoc """
  Context for CRM companies — CRUD, soft-delete, and search (for the contact
  form's company picker).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.Schemas.{Company, CompanyMembership, Contact}
  alias PhoenixKitCRM.Search
  alias PhoenixKitCRM.SoftDelete

  defp repo, do: RepoHelper.repo()

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
