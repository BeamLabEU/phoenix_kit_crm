defmodule PhoenixKitCRM.ManagedMirror do
  @moduledoc """
  Optional managed-organization creation through core's authorized lifecycle.

  Older supported core versions keep the ordinary mirror path. No email match
  grants management, and this path never falls back to independent signup.
  `manager_actor` comes only from the trusted signed browser session at mount.
  """
  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Companies
  alias PhoenixKitCRM.Mirror
  alias PhoenixKitCRM.Schemas.Company

  @actor PhoenixKit.Users.ManagedOrganizations.Actor
  @organizations PhoenixKit.Users.ManagedOrganizations
  @managers PhoenixKit.Users.OrganizationManagers

  def supported? do
    Code.ensure_loaded?(@organizations) and function_exported?(@organizations, :create, 3) and
      Code.ensure_loaded?(@managers) and function_exported?(@managers, :details, 2) and
      function_exported?(@managers, :search_for_creation, 2) and Code.ensure_loaded?(@actor)
  end

  def actor_from_session(session) do
    if supported?() do
      case core_call(@actor, :from_session, [session]) do
        {:ok, actor} -> actor
        _ -> nil
      end
    end
  end

  def available?(actor) do
    supported?() and Settings.get_boolean_setting("enable_organization_accounts", false) and
      match?({:ok, _}, core_call(@actor, :admin, [actor]))
  end

  def search(actor, term) do
    if available?(actor),
      do: core_call(@managers, :search_for_creation, [actor, term]),
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
           core_call(@organizations, :create, [
             actor,
             Mirror.attrs_from(:company, company, managed: true),
             first_manager_uuid
           ]),
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

  # Optional APIs are absent at our published core floor. Keep their dispatch
  # dynamic after the capability check, including on compilers checking remotes.
  defp core_call(module, function, args), do: apply(module, function, args)
end
