defmodule PhoenixKitCRM.Web.CompanyShowLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp unique, do: System.unique_integer([:positive])

  defp org_user_fixture(attrs) do
    base = %{
      "email" => "org-#{unique()}@example.test",
      "password" => "Sup3rSecret!24",
      "account_type" => "organization",
      "organization_name" => "Acme #{unique()}"
    }

    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
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

  describe "mirror account status (read-only)" do
    test "a linked company shows the mirror user's display name, linking to their admin page",
         %{conn: conn} do
      user = org_user_fixture(%{"organization_name" => "Globex Corp"})
      {:ok, company} = Companies.create_company(%{"name" => "Initech"})
      {:ok, company} = Companies.connect_user(company, user.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

      assert html =~ "Mirror account"
      assert html =~ "Globex Corp"
      assert html =~ ~s(href="/en/admin/users/view/#{user.uuid}")
    end

    test "an unlinked company shows None", %{conn: conn} do
      {:ok, company} = Companies.create_company(%{"name" => "Initech"})

      {:ok, _view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

      assert html =~ "Mirror account"
      assert html =~ "None"
    end
  end
end
