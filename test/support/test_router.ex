defmodule PhoenixKitCRM.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs produced
  by `PhoenixKitCRM.Paths` so `live/2` calls in tests use the same URLs the
  LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the settings
  table is unavailable, and admin paths get the default locale ("en") prefix — so
  the base becomes `/en/admin/crm`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitCRM.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/crm", PhoenixKitCRM.Web do
    pipe_through(:browser)

    live_session :crm_test,
      layout: {PhoenixKitCRM.Test.Layouts, :app},
      on_mount: {PhoenixKitCRM.Test.Hooks, :assign_scope} do
      live("/", CRMLive, :index)

      # `new`/`:uuid/edit` must precede `:uuid` so they aren't captured as an id.
      live("/contacts", ContactsLive, :index)
      live("/contacts/new", ContactFormLive, :new)
      live("/contacts/:uuid/edit", ContactFormLive, :edit)
      live("/contacts/:uuid", ContactShowLive, :show)

      live("/companies", CompaniesLive, :index)
      live("/companies/new", CompanyFormLive, :new)
      live("/companies/:uuid/edit", CompanyFormLive, :edit)
      live("/companies/:uuid", CompanyShowLive, :show)

      # OrganizationsView doesn't have a "Live" suffix (production reaches
      # it via a Tab.new!(live_view: ...) auto-route, not PhoenixKitCRM.Routes),
      # so `as:` can't be inferred here — name it explicitly.
      live("/organizations", OrganizationsView, :index, as: :crm_organizations)

      live("/lists", ListsLive, :index)
      live("/lists/new", ListFormLive, :new)
      live("/lists/:uuid/edit", ListFormLive, :edit)
      live("/lists/:uuid/members", ListMembersLive, :index)
      live("/lists/:uuid/import", ListImportLive, :index)
      live("/comparison", ComparisonLive, :index)

      # Production reaches both through core's auto-routes (a role subtab
      # registered at runtime; the settings tab); routed here so their
      # LiveViews can be driven by tests.
      live("/roles/:role_uuid", RoleView, :index, as: :crm_role)
      live("/settings", SettingsLive, :index, as: :crm_settings)
    end
  end
end
