defmodule PhoenixKitCRM do
  @moduledoc """
  CRM module for PhoenixKit.

  Implements the `PhoenixKit.Module` behaviour — discovered automatically at
  startup via the `@phoenix_kit_module` attribute. No explicit config is needed
  in the host application beyond adding this package to `deps`.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  @enabled_setting "crm_enabled"

  @impl PhoenixKit.Module
  def module_key, do: "crm"

  @impl PhoenixKit.Module
  def module_name, do: "CRM"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting(@enabled_setting, false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module(@enabled_setting, true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_setting, false, module_key())
  end

  @impl PhoenixKit.Module
  def version, do: "0.1.0"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "CRM",
      icon: "hero-users",
      description: "Customer relationship management module"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      %Tab{
        id: :admin_crm,
        label: gettext("CRM"),
        icon: "hero-users",
        path: "crm",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitCRM.Web.CRMLive, :index}
      },
      %Tab{
        id: :admin_crm_overview,
        label: gettext("Overview"),
        icon: "hero-users",
        path: "crm",
        priority: 651,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.CRMLive, :index}
      },
      %Tab{
        id: :admin_crm_companies,
        label: gettext("Companies"),
        path: "crm/companies",
        priority: 652,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.CompaniesView, :index},
        visible: fn _scope -> Settings.get_boolean_setting("crm_companies_enabled", false) end
      }
    ]
  end

  @impl PhoenixKit.Module
  def children do
    [
      %{
        id: PhoenixKitCRM.SidebarBootstrap,
        start: {Task, :start_link, [&PhoenixKitCRM.SidebarBootstrap.run/0]},
        restart: :temporary
      }
    ]
  end

  @doc """
  Refreshes the CRM role tabs in the Dashboard Registry.

  Called after enabling or disabling a role in `RoleSettings.set_enabled/2`.

  ## Known limitation

  Role subtabs live in the runtime-only namespace `:phoenix_kit_crm_roles`.
  If `PhoenixKit.Dashboard.Registry.load_admin_defaults/0` is ever invoked
  at runtime, this namespace is wiped; role tabs will reappear after the
  next `RoleSettings.set_enabled/2` call or an application restart.
  """
  @spec refresh_sidebar() :: :ok
  def refresh_sidebar do
    try do
      PhoenixKit.Dashboard.Registry.unregister(:phoenix_kit_crm_roles)
    rescue
      e ->
        Logger.warning(
          "[PhoenixKitCRM] refresh_sidebar unregister rescue: #{Exception.message(e)}"
        )

        :ok
    catch
      :exit, reason ->
        Logger.warning("[PhoenixKitCRM] refresh_sidebar unregister exit: #{inspect(reason)}")
        :ok
    end

    PhoenixKitCRM.SidebarBootstrap.run()
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_crm,
        label: "CRM",
        icon: "hero-users",
        path: "crm",
        priority: 650,
        level: :admin,
        parent: :admin_settings,
        permission: module_key(),
        match: :exact,
        live_view: {PhoenixKitCRM.Web.SettingsLive, :index}
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitCRM.Routes

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_crm]
end
