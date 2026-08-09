defmodule PhoenixKitCRM.Web.CompanyFormLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  test "renders the new company form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/crm/companies/new")
    assert html =~ "Name"
  end

  test "the way back is the chrome breadcrumb (page_section), not an in-body header",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/companies/new")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm/companies']", "Companies")
    refute html =~ "<h1"
    refute html =~ "<header"
  end

  test "creating a company persists it and logs crm.company_created with the actor",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/new")

    view |> form("form", company: %{name: "New Company"}) |> render_submit()

    assert [company] = Enum.filter(Companies.list_companies(), &(&1.name == "New Company"))

    assert_activity_logged("crm.company_created",
      resource_uuid: company.uuid,
      actor_uuid: scope.user.uuid
    )
  end

  test "editing a company updates it", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Original Company"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}/edit")

    view |> form("form", company: %{name: "Renamed Company"}) |> render_submit()

    assert Companies.get_company(company.uuid).name == "Renamed Company"
  end
end
