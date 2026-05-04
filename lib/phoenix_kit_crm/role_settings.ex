defmodule PhoenixKitCRM.RoleSettings do
  @moduledoc """
  Context for managing which roles have CRM access enabled.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.{Role, Roles}
  alias PhoenixKitCRM.RoleSetting

  @doc """
  Lists all roles that have CRM access enabled.

  Returns joined `%PhoenixKit.Users.Role{}` structs.

  ## Examples

      iex> list_enabled()
      [%Role{name: "Manager"}, ...]
  """
  @spec list_enabled() :: [Role.t()]
  def list_enabled do
    repo = RepoHelper.repo()

    query =
      from(role in Role,
        join: setting in RoleSetting,
        on: setting.role_uuid == role.uuid,
        where: setting.enabled == true,
        order_by: role.name
      )

    repo.all(query)
  end

  @doc """
  Lists all roles eligible for CRM access.

  Returns all non-system roles (i.e. roles where `is_system_role` is false).

  ## Examples

      iex> list_eligible_roles()
      [%Role{name: "Manager"}, %Role{name: "User"}, ...]
  """
  @spec list_eligible_roles() :: [Role.t()]
  def list_eligible_roles do
    Roles.list_roles()
    |> Enum.reject(& &1.is_system_role)
  end

  @doc """
  Returns whether the given role has CRM access enabled.

  ## Examples

      iex> enabled?("some-uuid")
      false
  """
  @spec enabled?(binary()) :: boolean()
  def enabled?(role_uuid) when is_binary(role_uuid) do
    repo = RepoHelper.repo()

    query =
      from(setting in RoleSetting,
        where: setting.role_uuid == ^role_uuid and setting.enabled == true
      )

    repo.exists?(query)
  end

  @doc """
  Enables or disables CRM access for a role.

  Upserts the setting row and triggers a sidebar refresh.

  ## Examples

      iex> set_enabled("some-uuid", true)
      {:ok, %RoleSetting{}}

      iex> set_enabled("some-uuid", false)
      {:ok, %RoleSetting{}}
  """
  @spec set_enabled(binary(), boolean()) :: {:ok, RoleSetting.t()} | {:error, Ecto.Changeset.t()}
  def set_enabled(role_uuid, enabled?) when is_binary(role_uuid) and is_boolean(enabled?) do
    repo = RepoHelper.repo()

    result =
      %RoleSetting{role_uuid: role_uuid}
      |> RoleSetting.changeset(%{enabled: enabled?})
      |> repo.insert(
        on_conflict: {:replace, [:enabled, :updated_at]},
        conflict_target: [:role_uuid]
      )

    case result do
      {:ok, setting} ->
        PhoenixKitCRM.refresh_sidebar()
        {:ok, setting}

      error ->
        error
    end
  end
end
