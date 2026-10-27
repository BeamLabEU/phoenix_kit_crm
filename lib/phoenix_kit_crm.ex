defmodule PhoenixKitCRM do
  @moduledoc """
  CRM module for PhoenixKit.

  Implements the `PhoenixKit.Module` behaviour — discovered automatically at
  startup via the `@phoenix_kit_module` attribute. No explicit config is needed
  in the host application beyond adding this package to `deps`.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitCRM.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.{Permissions, RolePermission}
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

  # Read from mix.exs at compile time rather than hardcoded, so this can never
  # drift from the package version again — it had: the published 0.6.1 reported
  # itself as 0.6.0.
  @version Mix.Project.config()[:version]

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "CRM",
      icon: "hero-users",
      description: "Customer relationship management module",
      sub_permissions: [
        # The base key reaches the CRM's records. The settings page (the
        # module's on/off switch, which roles get a CRM page, the party-role
        # vocabulary) and the role pages — which list every holder of a role
        # with their email — are administration, not record keeping.
        %{
          key: "settings",
          label: "Change the CRM settings",
          description:
            "Turn the CRM on or off, choose which roles get a CRM page and see those pages, and edit the party roles"
        }
      ]
    }
  end

  @settings_permission "crm.settings"

  @doc "The composed sub-key for the settings page and the role pages, for `Scope.can?/2`."
  @spec settings_permission() :: String.t()
  def settings_permission, do: @settings_permission

  @doc """
  Whether `scope` may change the CRM settings and open the role pages: the
  sub-key AND its base, read from the scope's permissions (which honour
  `"*"`, so an Owner passes). Deliberately not `Scope.can?/2`, which also
  requires the module to be ENABLED: this check adds no such condition of
  its own. In a host, core's admin mount gate still refuses a disabled
  module's pages, so re-enabling the CRM is core's Modules page.
  """
  @spec can_change_settings?(term()) :: boolean()
  def can_change_settings?(scope) do
    Scope.has_module_access?(scope, module_key()) and
      Scope.has_module_access?(scope, @settings_permission)
  rescue
    _ -> false
  end

  @doc """
  Whether `scope` may moderate comments on CRM records: the CRM is one
  permission with no per-record model, so CRM access means every record.
  Same rule `InteractionLinks.visible_resource_uuids/2` applies.
  """
  @spec comment_moderator?(term()) :: boolean()
  def comment_moderator?(scope) do
    enabled?() and Scope.has_module_access?(scope, module_key())
  rescue
    _ -> false
  end

  @doc """
  `phoenix_kit_comments`' moderation scope for the contact and company
  comment types: `:all` for a CRM-permission holder, else none.
  """
  @spec moderatable_resources(String.t(), term()) :: :all | [String.t()]
  def moderatable_resources(type, scope) when type in ["crm_contact", "crm_company"] do
    if comment_moderator?(scope), do: :all, else: []
  end

  def moderatable_resources(_type, _scope), do: []

  # Set once the settings split's backfill has run, so it never runs again
  # and an Owner's later revoke sticks.
  @settings_backfill_key "crm_settings_backfilled"

  @doc """
  One-time data repairs core calls on every boot. Each carries its own
  "already done" flag and runs once.

    * `crm.settings` is granted to every role that already holds the base
      `crm` key, so nobody loses the settings page or the role pages when
      they move behind the sub-key. A role granted `crm` afterwards gets the
      narrow meaning. The flag is set only once every grant succeeded.
  """
  @impl PhoenixKit.Module
  def migrate_legacy do
    if Settings.get_setting(@settings_backfill_key) == "true" do
      :ok
    else
      backfill_settings_permission()
    end
  rescue
    error ->
      Logger.warning("[PhoenixKitCRM] migrate_legacy failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  @doc false
  # `:grant` and `:holders` are parameters only so a test can make a grant or
  # the lookup fail and prove the flag then stays unset; production always
  # uses core's grant and `role_uuids_holding/1`.
  def backfill_settings_permission(opts \\ []) do
    grant = Keyword.get(opts, :grant, &Permissions.grant_permission/3)
    holders = Keyword.get(opts, :holders, &role_uuids_holding/1)

    # Read with a query that RAISES on failure: core's
    # `get_permissions_for_role/1` rescues an error to `[]`, which would read
    # as "nobody holds crm" and set the flag for good.
    case read_holders(holders) do
      {:ok, base, already} -> grant_settings_to(base, already, grant)
      {:error, :lookup_failed} = error -> error
    end
  end

  defp read_holders(holders) do
    {:ok, holders.(module_key()), MapSet.new(holders.(@settings_permission))}
  rescue
    error ->
      Logger.warning(
        "[PhoenixKitCRM] crm.settings backfill could not read the grants, will retry next boot: " <>
          Exception.message(error)
      )

      {:error, :lookup_failed}
  end

  defp grant_settings_to(base, already, grant) do
    failures =
      for role_uuid <- base,
          not MapSet.member?(already, role_uuid),
          result = grant.(role_uuid, @settings_permission, nil),
          not match?({:ok, _}, result) do
        {role_uuid, result}
      end

    case failures do
      [] ->
        Settings.update_setting_with_module(@settings_backfill_key, "true", module_key())
        :ok

      _ ->
        Logger.warning(
          "[PhoenixKitCRM] crm.settings backfill incomplete, will retry next boot: " <>
            inspect(failures)
        )

        {:error, {:settings_backfill_incomplete, failures}}
    end
  end

  # Every role holding `key`, straight from the role-permission table.
  defp role_uuids_holding(key) do
    RepoHelper.repo().all(
      from(rp in RolePermission,
        where: rp.module_key == ^key,
        select: rp.role_uuid,
        distinct: true
      )
    )
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
        permission: @settings_permission,
        match: :exact,
        live_view: {PhoenixKitCRM.Web.SettingsLive, :index},
        gettext_backend: PhoenixKitCRM.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitCRM.Routes

  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitCRM.Migrations

  @doc """
  The manifest of this module's tables, for `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor`; see `PhoenixKitCRM.ExpectedSchema`.
  """
  # No `@impl`, so this compiles against a core that lacks the callback.
  def expected_schema, do: PhoenixKitCRM.ExpectedSchema

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_crm]

  @impl PhoenixKit.Module
  def media_reorganizer, do: PhoenixKitCRM.MediaReorganizer

  # Project-extension contribution to the `phoenix_kit_projects` hub — the
  # duck-typed one-way contract (same shape as dashboards' widget contract):
  # its Extensions.Registry discovers this function; no dependency on the
  # projects package. The Client tab links a CRM company to a project via
  # per-instance CONFIG (company_uuid — no FK, set in the project's
  # Modules & features panel) and renders read-only company/contacts/
  # interactions context inside the project.
  # The calendar module's external-sources hook
  # (`PhoenixKitCalendar.ExternalSources`), discovered at runtime the same
  # way — no dependency on that package either. A person's calendar shows
  # the interactions they are in: planned, happened and cancelled.
  @doc false
  def phoenix_kit_calendar_sources do
    [
      %{
        key: PhoenixKitCRM.CalendarItems.source(),
        label: gettext("Client interactions"),
        module_key: "crm",
        items: {PhoenixKitCRM.CalendarItems, :for_user}
      }
    ]
  end

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
          %{
            key: "company_uuid",
            type: :select,
            label: "Company",
            # Lazy option source (the hub's ConfigOptions `{module, fun}`
            # form) — the admin picks a company by name instead of pasting
            # a uuid copied off the CRM company page.
            options: {PhoenixKitCRM.Companies, :company_options}
          }
        ],
        # `log_interaction` is the tab's write: logging a meeting on the
        # project, with the attendees' time into the project's ledger. The
        # hub resolves it against the project's role floors (an extension
        # action lands at member) and hands the tab `can_write`.
        permission_actions: [:view, :log_interaction],
        # The project's interactions on the projects JSON API
        # (`/ext/interactions`) — `PhoenixKitCRM.ProjectApi`.
        api: [PhoenixKitCRM.ProjectApi, PhoenixKitCRM.CompanyApi],
        # The project's interactions on its Calendar tab, read-only: what is
        # planned, what happened, what was cancelled
        # (`PhoenixKitCRM.CalendarItems.for_project/3`).
        calendar: {PhoenixKitCRM.CalendarItems, :for_project},
        # The client's name on the projects list, for the whole page of
        # projects in one go (`PhoenixKitCRM.ProjectColumns.for_projects/1`).
        project_columns: {PhoenixKitCRM.ProjectColumns, :for_projects}
      }
    ]
  end

  # Core's `:phoenix_kit_js_sources` compiler folds this into the host's module
  # JS bundle.
  @impl PhoenixKit.Module
  def js_sources do
    [
      %{
        app: :phoenix_kit_crm,
        file: "static/assets/phoenix_kit_crm.js",
        global: "PhoenixKitCRMHooks"
      }
    ]
  end

  # The CRM's linkable records, for core's resolver and the `#` typeahead:
  # contacts and companies resolve (a host used to register these two by
  # config; declaring them here makes that automatic), and an interaction
  # is searchable and visible too — `InteractionLinks` is what lets a task
  # say "from this meeting" and the meeting list the tasks.
  @impl PhoenixKit.Module
  def resource_links do
    %{
      "crm_contact" => __MODULE__,
      "crm_company" => __MODULE__,
      PhoenixKitCRM.InteractionLinks.type() => PhoenixKitCRM.InteractionLinks
    }
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
