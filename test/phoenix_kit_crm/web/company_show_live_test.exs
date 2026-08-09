defmodule PhoenixKitCRM.Web.CompanyShowLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the company's name", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    assert html =~ "Initech"
  end

  test "redirects to the companies list for an unknown uuid", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, "/en/admin/crm/companies/#{Ecto.UUID.generate()}")

    assert to =~ "/admin/crm/companies"
  end

  test "has a chrome breadcrumb back to Companies (the rich in-body header stays, on purpose)",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm/companies']", "Companies")
  end
end
