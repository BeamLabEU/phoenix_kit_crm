defmodule PhoenixKitCRM do
  @moduledoc """
  CRM module for PhoenixKit.

  Implements the `PhoenixKit.Module` behaviour — discovered automatically at
  startup via the `@phoenix_kit_module` attribute. No explicit config is needed
  in the host application beyond adding this package to `deps`.
  """

  use PhoenixKit.Module

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKitCRM.{Companies, Contacts, Paths}
  alias PhoenixKitCRM.Schemas.{Company, Contact}

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
  def version, do: "0.4.1"

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
      Tab.new!(
        id: :admin_crm,
        label: "CRM",
        icon: "hero-users",
        path: "/admin/crm",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitCRM.Web.CRMLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      ),
      Tab.new!(
        id: :admin_crm_overview,
        label: "Overview",
        icon: "hero-users",
        path: "/admin/crm",
        priority: 651,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.CRMLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      ),
      Tab.new!(
        id: :admin_crm_contacts,
        label: "Contacts",
        icon: "hero-user",
        path: "/admin/crm/contacts",
        priority: 652,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.ContactsLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      ),
      Tab.new!(
        id: :admin_crm_companies,
        label: "Companies",
        icon: "hero-building-office-2",
        path: "/admin/crm/companies",
        priority: 653,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.CompaniesLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      ),
      Tab.new!(
        id: :admin_crm_lists,
        label: "Lists",
        icon: "hero-envelope",
        path: "/admin/crm/lists",
        priority: 654,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.ListsLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      ),
      Tab.new!(
        id: :admin_crm_comparison,
        label: "Compare",
        icon: "hero-arrows-right-left",
        path: "/admin/crm/comparison",
        # Compare works on contact lists, so it sits right after Lists — which
        # is where it is declared here. Priority, not source order, is what the
        # sidebar sorts on.
        priority: 655,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.ComparisonLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      ),
      Tab.new!(
        id: :admin_crm_organizations,
        label: "Organizations",
        path: "/admin/crm/organizations",
        priority: 656,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_crm,
        live_view: {PhoenixKitCRM.Web.OrganizationsView, :index},
        visible: fn _scope ->
          Settings.get_boolean_setting("enable_organization_accounts", false)
        end,
        gettext_backend: PhoenixKitCRM.Gettext
      )
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
        priority: 924,
        level: :admin,
        parent: :admin_settings,
        permission: module_key(),
        match: :exact,
        live_view: {PhoenixKitCRM.Web.SettingsLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitCRM.Routes

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_crm]

  # Project-extension contribution to the `phoenix_kit_projects` hub — the
  # duck-typed one-way contract (same shape as dashboards' widget contract):
  # its Extensions.Registry discovers this function; no dependency on the
  # projects package. The Client tab links a CRM company to a project via
  # per-instance CONFIG (company_uuid — no FK, set in the project's
  # Modules & features panel) and renders read-only company/contacts/
  # interactions context inside the project.
  @doc false
  def phoenix_kit_project_extensions do
    [
      %{
        key: "crm_client",
        name: "Client",
        description: "Link a CRM company to this project — contacts and interactions in context",
        icon: "hero-building-office-2",
        module_key: "crm",
        default_enabled: false,
        tabs: [
          %{
            key: "client",
            label: "Client",
            icon: "hero-building-office-2",
            lv: PhoenixKitCRM.Web.ProjectClientLive
          }
        ],
        config_schema: [
          %{key: "company_uuid", type: :string, label: "Company UUID"}
        ],
        permission_actions: [:view]
      }
    ]
  end

  # No `@impl` on purpose — older core releases don't declare the `js_sources/0`
  # callback, and annotating it would warn (and fail `--warnings-as-errors`).
  # Core's `:phoenix_kit_js_sources` compiler folds this into the host's module
  # JS bundle where present. (Mirrors `phoenix_kit_projects`.)
  def js_sources do
    [
      %{
        app: :phoenix_kit_crm,
        file: "static/assets/phoenix_kit_crm.js",
        global: "PhoenixKitCRMHooks"
      }
    ]
  end

  @doc """
  phoenix_kit_comments back-link resolver. Turns commented contact/company uuids
  into `%{uuid => %{title, path}}` chips for the central Comments admin, so each
  comment links back to the record it was made on (with the contact/company name
  as the label).

  Paths are RAW (no URL prefix) — the comments module applies the prefix/locale
  itself. Registered via the host's config (see hello_world for the pattern):

      config :phoenix_kit, :comment_resource_handlers, %{
        "crm_contact" => PhoenixKitCRM,
        "crm_company" => PhoenixKitCRM
      }

  Dispatched per `resource_type`, so each call's uuids are all one kind; we
  resolve against both tables and merge, which is harmless for the empty side.
  """
  @spec resolve_comment_resources([binary()]) :: %{binary() => map()}
  def resolve_comment_resources(uuids) when is_list(uuids) do
    contacts =
      uuids
      |> Contacts.list_by_uuids()
      |> Map.new(fn c ->
        {c.uuid, %{title: Contact.display_name(c), path: Paths.contact_raw(c.uuid)}}
      end)

    companies =
      uuids
      |> Companies.list_by_uuids()
      |> Map.new(fn co ->
        {co.uuid, %{title: Company.display_name(co), path: Paths.company_raw(co.uuid)}}
      end)

    Map.merge(contacts, companies)
  rescue
    _ -> %{}
  end
end
