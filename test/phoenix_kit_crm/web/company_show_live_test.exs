defmodule PhoenixKitCRM.Web.CompanyShowLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp unique, do: System.unique_integer([:positive])

  # LiveViewTest does not expose assigns. The connected process is the
  # LiveView itself (`%Socket{}`) or a Channel wrapping one.
  defp live_assigns(view) do
    case :sys.get_state(view.pid) do
      %{assigns: assigns} -> assigns
      %{socket: %{assigns: assigns}} -> assigns
      other -> flunk("cannot read LiveView assigns from #{inspect(other)}")
    end
  end

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

  test "the show strip is core nav_tabs (border) with prefixed patch hrefs", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    assert html =~ ~s(role="tablist")
    assert html =~ "tabs-border"
    assert has_element?(view, "a.tab-active", "Overview")

    assert has_element?(
             view,
             ~s{a[href="/en/admin/crm/companies/#{company.uuid}?tab=members"]},
             "Members"
           )
  end

  # The Catalogue tab 500ed on first load because @column_picker_available and
  # @catalogue_column_catalog were only assigned from the picker event
  # handlers, never from handle_params. Catalogue is a soft-dep and is not
  # loaded in this suite, so ?tab=catalogue clamps to Overview and a
  # render-succeeds test would pass *without* the fix. The two assigns are
  # set unconditionally, so reading them off the LiveView process is the
  # lock that survives the clamp.
  test "catalogue picker assigns are present on first handle_params (KeyError regression)",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=catalogue")

    assigns = live_assigns(view)
    assert is_boolean(assigns.column_picker_available)
    assert is_list(assigns.catalogue_column_catalog)
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
