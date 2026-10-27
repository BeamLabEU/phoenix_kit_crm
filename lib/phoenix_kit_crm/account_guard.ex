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
  alias PhoenixKit.Users.{Role, RoleAssignment}

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
