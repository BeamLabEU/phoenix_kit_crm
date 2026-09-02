defmodule PhoenixKitCRM.RoleSettings do
  @moduledoc """
  Context for managing which roles have CRM access enabled.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.{Role, RoleAssignment, Roles}
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
  Lists CRM-enabled roles with the count of users assigned to each role.

  Single query — left-joins `role_assignments` so roles with zero users still
  appear (count = 0). Used by the CRM overview page in place of N+1
  `count_users_with_role/1` calls.

  ## Examples

      iex> list_enabled_with_user_counts()
      [%{uuid: "...", name: "Manager", count: 3}, ...]
  """
  @spec list_enabled_with_user_counts() :: [%{uuid: binary(), name: String.t(), count: integer()}]
  def list_enabled_with_user_counts do
    repo = RepoHelper.repo()

    query =
      from(role in Role,
        join: setting in RoleSetting,
        on: setting.role_uuid == role.uuid,
        left_join: assignment in RoleAssignment,
        on: assignment.role_uuid == role.uuid,
        where: setting.enabled == true,
        group_by: [role.uuid, role.name],
        order_by: role.name,
        select: %{uuid: role.uuid, name: role.name, count: count(assignment.uuid)}
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

  Upserts the setting row, logs the change (this grants or revokes CRM access
  for everyone holding the role — the one mutation on the settings page, and
  it was the module's only unlogged one), and triggers a sidebar refresh.
  Pass `:actor_uuid` in `opts` so the audit entry records who flipped it.

  ## Examples

      iex> set_enabled("some-uuid", true)
      {:ok, %RoleSetting{}}

      iex> set_enabled("some-uuid", false, actor_uuid: admin.uuid)
      {:ok, %RoleSetting{}}
  """
  @spec set_enabled(binary(), boolean(), keyword()) ::
          {:ok, RoleSetting.t()} | {:error, Ecto.Changeset.t()}
  def set_enabled(role_uuid, enabled?, opts \\ [])
      when is_binary(role_uuid) and is_boolean(enabled?) do
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
        PhoenixKitCRM.Activity.log(
          if(enabled?, do: "crm.role_access_enabled", else: "crm.role_access_disabled"),
          actor_uuid: Keyword.get(opts, :actor_uuid),
          resource_type: "crm_role_setting",
          resource_uuid: role_uuid
        )

        PhoenixKitCRM.refresh_sidebar()
        {:ok, setting}

      error ->
        error
    end
  end
end
