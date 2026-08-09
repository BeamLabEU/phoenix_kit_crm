defmodule PhoenixKitCRM.Routes do
  @moduledoc """
  Route definitions for the CRM module.

  List page routes for the parent CRM tab and the Organizations subtab are
  auto-generated from `live_view:` fields returned by the
  `c:PhoenixKit.Module.admin_tabs/0` callback.
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
    contact_form = Web.ContactFormLive
    contact_show = Web.ContactShowLive
    company_form = Web.CompanyFormLive
    company_show = Web.CompanyShowLive
    list_form = Web.ListFormLive
    list_members = Web.ListMembersLive
    list_import = Web.ListImportLive

    quote do
      live("/admin/crm/role/:role_uuid", unquote(role_view), :index,
        as: :"crm_role_view#{unquote(suffix)}"
      )

      # Contacts — `new` must precede `:uuid` so it isn't captured as an id.
      live("/admin/crm/contacts/new", unquote(contact_form), :new,
        as: :"crm_contact_new#{unquote(suffix)}"
      )

      live("/admin/crm/contacts/:uuid/edit", unquote(contact_form), :edit,
        as: :"crm_contact_edit#{unquote(suffix)}"
      )

      live("/admin/crm/contacts/:uuid", unquote(contact_show), :show,
        as: :"crm_contact_show#{unquote(suffix)}"
      )

      # Companies
      live("/admin/crm/companies/new", unquote(company_form), :new,
        as: :"crm_company_new#{unquote(suffix)}"
      )

      live("/admin/crm/companies/:uuid/edit", unquote(company_form), :edit,
        as: :"crm_company_edit#{unquote(suffix)}"
      )

      live("/admin/crm/companies/:uuid", unquote(company_show), :show,
        as: :"crm_company_show#{unquote(suffix)}"
      )

      # Lists — `new` must precede `:uuid` so it isn't captured as an id.
      live("/admin/crm/lists/new", unquote(list_form), :new,
        as: :"crm_list_new#{unquote(suffix)}"
      )

      live("/admin/crm/lists/:uuid/edit", unquote(list_form), :edit,
        as: :"crm_list_edit#{unquote(suffix)}"
      )

      live("/admin/crm/lists/:uuid/members", unquote(list_members), :index,
        as: :"crm_list_members#{unquote(suffix)}"
      )

      live("/admin/crm/lists/:uuid/import", unquote(list_import), :index,
        as: :"crm_list_import#{unquote(suffix)}"
      )

      # NOTE: no route for ComparisonLive here. Its tab in `admin_tabs/0`
      # carries both `path: "/admin/crm/comparison"` and
      # `live_view: {Web.ComparisonLive, :index}`, so core generates the
      # route from the tab; declaring it here too made the host router
      # compile with "this clause cannot match because a previous clause
      # matches the same pattern", in both the root and the /:locale scope.
      #
      # Path, LiveView, action, pipeline and live_session are identical
      # either way, so dispatch is unchanged — but the generated path
      # HELPER is not: the tab route is `as: :admin_crm_comparison`, where
      # this clause was `as: :crm_comparison` / `:crm_comparison_locale`.
      # That is the same shape the other list-index tabs (Contacts,
      # Companies, Lists) already have — Comparison was the lone outlier —
      # and nothing links to it by helper: in-repo callers go through
      # `Paths.comparison/0`, which builds the path as a string.
    end
  end
end
