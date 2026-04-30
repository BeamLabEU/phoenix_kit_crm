defmodule PhoenixKitCRM.Routes do
  @moduledoc """
  Route definitions for the CRM module.

  List page routes for the parent CRM tab and the Companies subtab are
  auto-generated from `live_view:` fields in `PhoenixKitCRM.admin_tabs/0`.
  Parameterized routes (e.g. per-role pages) live here because dynamic
  tabs registered into `PhoenixKit.Dashboard.Registry` at runtime do not
  trigger router compilation.
  """

  alias PhoenixKitCRM.Web

  def admin_routes do
    build_admin_routes("")
  end

  def admin_locale_routes do
    build_admin_routes("_locale")
  end

  defp build_admin_routes(suffix) do
    role_view = Web.RoleView

    quote do
      live("/admin/crm/role/:role_uuid", unquote(role_view), :index,
        as: :"crm_role_view#{unquote(suffix)}"
      )
    end
  end
end
