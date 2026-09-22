defmodule PhoenixKitCRM.Web.CompanyFormLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  # LiveView recovers a form's input after a reconnect only when the form
  # has an id beside its phx-change.
  test "the form carries the id LiveView recovers it by", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/new")
    assert has_element?(view, "form#company-form[phx-change=validate]")
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

  # `metadata` is server-owned (the avatar pointer, the trash stash, import
  # provenance); a crafted form param must neither set nor replace it.
  test "a crafted metadata param on save is ignored", %{conn: conn} do
    {:ok, company} =
      Companies.create_company(%{
        "name" => "Kept Co",
        "metadata" => %{"imported_from" => "cat_suppliers"}
      })

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}/edit")

    view
    |> element("form#company-form")
    |> render_submit(%{
      "company" => %{"name" => "Kept Co", "metadata" => %{"avatar_uuid" => Ecto.UUID.generate()}}
    })

    assert Companies.get_company(company.uuid).metadata == %{"imported_from" => "cat_suppliers"}
  end
end
