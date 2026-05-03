defmodule PhoenixKitCRM.SidebarBootstrap do
  @moduledoc """
  Registers CRM role subtabs into `PhoenixKit.Dashboard.Registry` under the
  namespace `:phoenix_kit_crm_roles`.

  Invoked twice:

    * At boot via `PhoenixKitCRM.children/0` as a one-shot `Task`
      (`restart: :temporary`).
    * After every `PhoenixKitCRM.RoleSettings.set_enabled/2` call, through
      `PhoenixKitCRM.refresh_sidebar/0`.

  ## Known limitation

  `PhoenixKit.Dashboard.Registry.load_admin_defaults/0` wipes
  runtime-registered namespaces, including `:phoenix_kit_crm_roles`. If the
  host app ever invokes it at runtime, CRM role subtabs will disappear
  until the next `set_enabled/2` call or application restart. This is an
  accepted trade-off for avoiding a persistent watcher GenServer.
  """

  require Logger

  alias PhoenixKit.Dashboard.{Registry, Tab}
  alias PhoenixKitCRM.RoleSettings

  @doc """
  Registers CRM role tabs into the Dashboard Registry.

  No-op when the CRM module is disabled. Swallows errors/exits if the
  Registry is not yet started (e.g. during tests or boot race).
  """
  @spec run() :: :ok
  def run do
    if PhoenixKitCRM.enabled?() do
      try do
        tabs =
          RoleSettings.list_enabled()
          |> Enum.map(&role_tab/1)

        Registry.register(:phoenix_kit_crm_roles, tabs)
        :ok
      rescue
        e ->
          Logger.warning("[PhoenixKitCRM] SidebarBootstrap rescue: #{Exception.message(e)}")

          :ok
      catch
        :exit, reason ->
          Logger.warning("[PhoenixKitCRM] SidebarBootstrap exit: #{inspect(reason)}")

          :ok
      end
    else
      :ok
    end
  end

  defp role_tab(role) do
    %Tab{
      id: :"crm_role_#{role.uuid}",
      label: role.name,
      path: "crm/role/#{role.uuid}",
      priority: 660,
      level: :admin,
      permission: PhoenixKitCRM.module_key(),
      parent: :admin_crm,
      live_view: {PhoenixKitCRM.Web.RoleView, :index}
    }
  end
end
