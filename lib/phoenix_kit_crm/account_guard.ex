defmodule PhoenixKitCRM.AccountGuard do
  @moduledoc """
  Which user accounts the CRM may offer or link at all.

  The "Link existing…" pickers are reached with the everyday `crm` key and
  show each candidate's name and email. An account holding the site's Owner
  or Admin role is never a candidate: the CRM has no business listing the
  people who run the site, or binding their login to a contact or company
  record. `Contacts.link_user/2`, `Contacts.connect_user/2` and
  `Companies.connect_user/2` refuse such an account server-side
  (`{:error, :privileged_account}`), so a crafted uuid or email fails like
  the picker that never showed it.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.{Role, RoleAssignment}
  alias PhoenixKitCRM.Mirror

  @doc """
  Writes mirror fields only while the current account is an unclaimed CRM
  placeholder. Re-reads and locks the user until the write commits, so a
  stale caller cannot rewrite an account claimed since it was loaded.

  With `only_blank: true`, fields filled since the caller's read are kept.
  Real and privileged accounts are returned unchanged.
  """
  @spec update_placeholder_profile(User.t(), map(), keyword()) ::
          {:ok, User.t()} | {:error, term()}
  def update_placeholder_profile(%User{uuid: uuid}, attrs, opts \\ []) do
    repo = RepoHelper.repo()

    repo.transaction(fn ->
      current =
        repo.one(from(u in User, where: u.uuid == ^uuid, lock: "FOR NO KEY UPDATE")) ||
          repo.rollback(:user_not_found)

      case update_current_placeholder(current, profile_attrs(current, attrs, opts)) do
        {:ok, updated} -> updated
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp profile_attrs(user, attrs, opts) do
    if Keyword.get(opts, :only_blank, false),
      do: Map.filter(attrs, fn {field, _value} -> blank?(Map.get(user, field)) end),
      else: attrs
  end

  defp update_current_placeholder(user, attrs) do
    if map_size(attrs) > 0 and Mirror.placeholder_user?(user) and not privileged?(user.uuid),
      do: Auth.update_user_profile(user, attrs),
      else: {:ok, user}
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  @doc "The Owner and Admin role names (core's system roles that run the site)."
  @spec privileged_role_names() :: [String.t()]
  def privileged_role_names do
    roles = Role.system_roles()
    [roles.owner, roles.admin]
  end

  @doc "The uuids of every account holding the Owner or Admin role, in one read."
  @spec privileged_user_uuids() :: MapSet.t()
  def privileged_user_uuids do
    names = privileged_role_names()

    from(ra in RoleAssignment,
      join: r in Role,
      on: r.uuid == ra.role_uuid,
      where: r.name in ^names,
      select: ra.user_uuid,
      distinct: true
    )
    |> RepoHelper.repo().all()
    |> MapSet.new()
  end

  @doc "Whether the account `user_uuid` holds the Owner or Admin role."
  @spec privileged?(binary() | nil) :: boolean()
  def privileged?(user_uuid) when is_binary(user_uuid) do
    names = privileged_role_names()

    RepoHelper.repo().exists?(
      from(ra in RoleAssignment,
        join: r in Role,
        on: r.uuid == ra.role_uuid,
        where: ra.user_uuid == ^user_uuid and r.name in ^names
      )
    )
  end

  def privileged?(_), do: false
end
