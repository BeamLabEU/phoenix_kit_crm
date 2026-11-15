defmodule PhoenixKitCRM.ManagedMirror do
  @moduledoc """
  Managed-organization creation through core's authorized lifecycle.

  Every core from the 3.5.0 floor ships that API. No email match grants
  management, and this path never falls back to independent signup.
  `manager_actor` comes only from the trusted signed browser session at mount.
  The option stays hidden unless organization accounts are on and the actor
  is an administrator of their own account.
  """
  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Users.ManagedOrganizations.Actor
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKitCRM.Companies
  alias PhoenixKitCRM.Mirror
  alias PhoenixKitCRM.Schemas.Company

  def actor_from_session(session) do
    case Actor.from_session(session) do
      {:ok, actor} -> actor
      _ -> nil
    end
  end

  def available?(actor) do
    Settings.get_boolean_setting("enable_organization_accounts", false) and
      match?({:ok, _}, Actor.admin(actor))
  end

  def search(actor, term) do
    if available?(actor),
      do: OrganizationManagers.search_for_creation(actor, term),
      else: {:error, :forbidden}
  end

  def create(%Company{uuid: uuid}, opts) do
    actor = Keyword.get(opts, :manager_actor)

    with {:ok, uuid} <- Ecto.UUID.cast(uuid), true <- available?(actor) do
      RepoHelper.repo().transaction(fn ->
        create_locked(uuid, actor, Keyword.get(opts, :first_manager_uuid))
      end)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp create_locked(uuid, actor, first_manager_uuid) do
    repo = RepoHelper.repo()

    company =
      repo.one(from(c in Company, where: c.uuid == ^uuid, lock: "FOR NO KEY UPDATE")) ||
        repo.rollback(:not_found)

    if company.user_uuid, do: repo.rollback(:already_linked)
    if company.status == "trashed", do: repo.rollback(:not_found)

    with {:ok, user} <-
           ManagedOrganizations.create(
             actor,
             Mirror.attrs_from(:company, company, managed: true),
             first_manager_uuid
           ),
         {:ok, user} <-
           Auth.merge_user_custom_fields(user, %{"source" => "crm_company"},
             ensure_definitions: false
           ),
         {:ok, linked} <- Companies.connect_user(company, user.uuid) do
      {linked, user}
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end
end
