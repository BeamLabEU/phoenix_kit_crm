defmodule PhoenixKitCRM.Web.CustomPartyRolesLiveTest do
  @moduledoc """
  An admin-defined role (V10) on every page that renders roles: ticked in the
  company and contact forms, badged and filtered on the lists, a tile on the
  overview, and — archived — still shown where it is held but never offered.
  """
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.{Companies, Contacts, PartyRoles, PartyRoleTypes}

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCRM.enable_system()

    {:ok, carrier} =
      PartyRoleTypes.ensure("carrier",
        names: %{"en" => "Carrier"},
        badge: "badge-secondary",
        icon: "hero-truck"
      )

    {:ok, conn: put_test_scope(conn, fake_scope()), carrier: carrier}
  end

  defp company_fixture(name \\ "Fast Freight") do
    {:ok, company} = Companies.create_company(%{"name" => name})
    company
  end

  describe "the company form" do
    test "offers the custom role beside the built-ins, in position order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/new")

      assert has_element?(view, ~s{input[name="roles[]"][value="carrier"]})
      assert has_element?(view, "label", "Carrier")

      html = render(view)
      positions = for k <- ~w(supplier manufacturer customer partner carrier), do: pos(html, k)
      assert positions == Enum.sort(positions)
    end

    test "ticking it on a new company grants it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/new")

      view
      |> form("#company-form", %{"company" => %{"name" => "Hauler OÜ"}, "roles" => ["carrier"]})
      |> render_submit()

      company = Enum.find(Companies.list_companies(), &(&1.name == "Hauler OÜ"))
      assert PartyRoles.has_role?(company, "carrier")
      assert [%{uuid: uuid}] = PartyRoles.list_parties_with_role("carrier")
      assert uuid == company.uuid
    end

    test "unticking it revokes it", %{conn: conn} do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "carrier")

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}/edit")
      assert has_element?(view, ~s{input[name="roles[]"][value="carrier"][checked]})

      view |> form("#company-form", %{"roles" => []}) |> render_submit()
      refute PartyRoles.has_role?(company, "carrier")
    end

    test "an archived role is not offered to a company that doesn't hold it", %{
      conn: conn,
      carrier: carrier
    } do
      {:ok, _} = PartyRoleTypes.archive_type(carrier)

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/new")
      refute has_element?(view, ~s{input[name="roles[]"][value="carrier"]})
    end

    test "an archived role a company holds is shown ticked, kept on re-save, and can be unticked",
         %{conn: conn, carrier: carrier} do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "carrier")
      {:ok, _} = PartyRoleTypes.archive_type(carrier)

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}/edit")
      assert has_element?(view, ~s{input[name="roles[]"][value="carrier"][checked]})
      assert has_element?(view, "label", "archived")

      # Saving the form untouched must not strip it or fail on it.
      view |> form("#company-form", %{}) |> render_submit()
      assert PartyRoles.has_role?(company, "carrier")

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}/edit")
      view |> form("#company-form", %{"roles" => []}) |> render_submit()
      refute PartyRoles.has_role?(company, "carrier")
    end

    test "a forged roles[] value for a role that was never offered grants nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/new")

      render_submit(view, "save", %{
        "company" => %{"name" => "Forger"},
        "roles" => ["carrier", "not_a_role"]
      })

      company = Enum.find(Companies.list_companies(), &(&1.name == "Forger"))
      assert PartyRoles.has_role?(company, "carrier")
      assert Enum.map(PartyRoles.list_roles(company), & &1.role) == ["carrier"]
    end
  end

  describe "the contact form" do
    test "offers the custom role and grants it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/new")
      assert has_element?(view, ~s{input[name="roles[]"][value="carrier"]})

      view
      |> form("form", %{"contact" => %{"name" => "Solo Driver"}, "roles" => ["carrier"]})
      |> render_submit()

      contact = Enum.find(Contacts.list_contacts(), &(&1.name == "Solo Driver"))
      assert PartyRoles.has_role?(contact, "carrier")
    end
  end

  describe "the lists" do
    test "renamed built-ins use the new name in result counts on both lists", %{conn: conn} do
      supplier = PartyRoleTypes.get_type_by_key("supplier")
      {:ok, _} = PartyRoleTypes.update_type(supplier, %{"name" => "Vendor"})
      {:ok, _} = PartyRoles.grant_role(company_fixture(), "supplier")
      {:ok, contact} = Contacts.create_contact(%{"name" => "Vendor contact"})
      {:ok, _} = PartyRoles.grant_role(contact, "supplier")

      for path <- ~w(companies contacts) do
        {:ok, view, _html} = live(conn, "/en/admin/crm/#{path}?filter=supplier")

        assert has_element?(view, "a.tab-active", "Vendor (1)")
        assert render(view) =~ "Vendor: 1"
        refute render(view) =~ "1 supplier"
      end
    end

    test "the badge carries the role's name and badge class; a tab counts the holders",
         %{conn: conn} do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "carrier")
      company_fixture("Plain Co")

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies")

      assert has_element?(view, "span.badge.badge-secondary", "Carrier")

      assert has_element?(
               view,
               ~s{a[href="#{admin()}/crm/companies?filter=carrier"]},
               "Carrier (1)"
             )

      {:ok, view, html} = live(conn, "/en/admin/crm/companies?filter=carrier")
      assert has_element?(view, "a.tab-active", "Carrier (1)")
      assert html =~ "Fast Freight"
      refute html =~ "Plain Co"
      assert html =~ "Carrier: 1"
    end

    test "the contacts list filters by the custom role too", %{conn: conn} do
      {:ok, driver} = Contacts.create_contact(%{"name" => "Solo Driver"})
      {:ok, _} = Contacts.create_contact(%{"name" => "Bystander"})
      {:ok, _} = PartyRoles.grant_role(driver, "carrier")

      {:ok, view, html} = live(conn, "/en/admin/crm/contacts?filter=carrier")

      assert has_element?(view, "a.tab-active", "Carrier (1)")
      assert html =~ "Solo Driver"
      refute html =~ "Bystander"
    end

    test "an archived role stays a tab and a badge while somebody holds it; an unheld one leaves",
         %{conn: conn, carrier: carrier} do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "carrier")
      {:ok, _} = PartyRoleTypes.archive_type(carrier)

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies")
      assert has_element?(view, ~s{a[href="#{admin()}/crm/companies?filter=carrier"]})
      assert has_element?(view, "span.badge.badge-secondary", "Carrier")

      {:ok, _} = PartyRoles.revoke_role(company, "carrier")
      {:ok, view, _html} = live(conn, "/en/admin/crm/companies")
      refute has_element?(view, ~s{a[href="#{admin()}/crm/companies?filter=carrier"]})
    end

    test "a filter naming no role is the All view, not an error", %{conn: conn} do
      company_fixture()
      {:ok, view, html} = live(conn, "/en/admin/crm/companies?filter=forwarder")
      assert has_element?(view, "a.tab-active", "All (1)")
      assert html =~ "Fast Freight"
    end
  end

  describe "the overview" do
    test "a tile for the custom role links the filtered index; zero stays visible unlinked",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/crm")
      assert html =~ "Carrier"
      refute has_element?(view, ~s{a[href="#{admin()}/crm/companies?filter=carrier"]})

      {:ok, _} = PartyRoles.grant_role(company_fixture(), "carrier")
      {:ok, view, _html} = live(conn, "/en/admin/crm")
      assert has_element?(view, ~s{a[href="#{admin()}/crm/companies?filter=carrier"]})
    end

    test "an archived role with no holders leaves the band", %{conn: conn, carrier: carrier} do
      {:ok, _} = PartyRoleTypes.archive_type(carrier)
      {:ok, _view, html} = live(conn, "/en/admin/crm")
      refute html =~ "Carrier"
    end
  end

  describe "the company page" do
    test "shows the custom badge on the overview tab", %{conn: conn} do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "carrier")

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")
      assert has_element?(view, "span.badge.badge-secondary", "Carrier")
    end
  end

  # Index of the role's checkbox in the rendered form -- the form's order.
  defp pos(html, key) do
    {index, _} = :binary.match(html, ~s(value="#{key}"))
    index
  end
end
