defmodule PhoenixKitCRM.Web.PartyRolesSettingsLiveTest do
  @moduledoc """
  Settings → CRM → Party roles: the list (reorder, archive, restore, delete)
  and the add / edit form.
  """
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.{Companies, PartyRoles, PartyRoleTypes, Paths}

  @list "/en/admin/crm/settings?tab=party-roles"
  @new "/en/admin/crm/settings/party-roles/new"

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCRM.enable_system()
    {:ok, conn: put_test_scope(conn, settings_scope())}
  end

  defp carrier! do
    {:ok, carrier} = PartyRoleTypes.ensure("carrier", name: "Carrier", badge: "badge-secondary")
    carrier
  end

  defp company_fixture do
    {:ok, company} = Companies.create_company(%{"name" => "Fast Freight"})
    company
  end

  describe "the list" do
    test "opens on the tab named in the URL and shows the built-ins in order, with holders", %{
      conn: conn
    } do
      {:ok, _} = PartyRoles.grant_role(company_fixture(), "supplier")

      {:ok, view, html} = live(conn, @list)

      assert has_element?(view, "#party-role-supplier", "Supplier")
      assert has_element?(view, "#party-role-supplier td", "1")
      assert has_element?(view, "#party-role-manufacturer")
      assert has_element?(view, ~s{a[href$="/party-roles/new"]}, "Add role")

      positions = for k <- ~w(supplier manufacturer customer partner), do: pos(html, k)
      assert positions == Enum.sort(positions)
    end

    test "a built-in can be edited but neither archived nor deleted", %{conn: conn} do
      {:ok, view, _html} = live(conn, @list)

      assert has_element?(view, "#party-role-supplier a", "Edit")
      refute has_element?(view, "#party-role-supplier button", "Archive")
      refute has_element?(view, "#party-role-supplier button", "Delete")
    end

    test "archive, then restore, a custom role", %{conn: conn} do
      carrier!()
      {:ok, view, _html} = live(conn, @list)

      view |> element("#party-role-carrier button", "Archive") |> render_click()
      assert has_element?(view, "#party-role-carrier", "Archived")
      refute PartyRoleTypes.active?("carrier")

      view |> element("#party-role-carrier button", "Restore") |> render_click()
      assert has_element?(view, "#party-role-carrier", "Active")
      assert PartyRoleTypes.active?("carrier")
    end

    test "delete removes an unused custom role", %{conn: conn} do
      carrier!()
      {:ok, view, _html} = live(conn, @list)

      view |> element("#party-role-carrier button", "Delete") |> render_click()

      refute has_element?(view, "#party-role-carrier")
      refute PartyRoleTypes.get_type_by_key("carrier")
    end

    test "delete of a role someone holds is refused and says to archive", %{conn: conn} do
      carrier!()
      {:ok, _} = PartyRoles.grant_role(company_fixture(), "carrier")
      {:ok, view, _html} = live(conn, @list)

      html = view |> element("#party-role-carrier button", "Delete") |> render_click()

      assert html =~ "archive it instead"
      assert has_element?(view, "#party-role-carrier")
      assert PartyRoleTypes.get_type_by_key("carrier")
    end

    test "forged events for a built-in or a stranger change nothing", %{conn: conn} do
      supplier = PartyRoleTypes.get_type_by_key("supplier")
      {:ok, view, _html} = live(conn, @list)

      assert render_click(view, "delete_party_role", %{"uuid" => supplier.uuid}) =~
               "built-in role cannot be deleted"

      assert render_click(view, "archive_party_role", %{"uuid" => supplier.uuid}) =~
               "built-in role cannot be archived"

      assert render_click(view, "delete_party_role", %{"uuid" => Ecto.UUID.generate()}) =~
               "not found"

      assert PartyRoleTypes.active?("supplier")
    end

    test "dropping a row persists the new order and logs it", %{conn: conn} do
      carrier = carrier!()
      {:ok, view, _html} = live(conn, @list)

      ordered =
        [carrier | Enum.reject(PartyRoleTypes.list_types(), &(&1.key == "carrier"))]
        |> Enum.map(& &1.uuid)

      render_hook(view, "reorder_party_roles", %{
        "ordered_ids" => ordered,
        "moved_id" => carrier.uuid
      })

      assert hd(PartyRoleTypes.list_types()).key == "carrier"
      assert_activity_logged("crm.party_role_types_reordered")
    end
  end

  describe "the form" do
    test "clearing an existing description saves the empty value", %{conn: conn} do
      {:ok, carrier} =
        PartyRoleTypes.ensure("carrier", name: "Carrier", description: "Moves goods")

      {:ok, view, _html} = live(conn, "/en/admin/crm/settings/party-roles/#{carrier.uuid}/edit")

      view
      |> form("#party-role-form", party_role: %{description: ""})
      |> render_change()

      view
      |> form("#party-role-form", party_role: %{description: ""})
      |> render_submit()

      assert_redirect(view, Paths.party_roles())
      assert PartyRoleTypes.description(PartyRoleTypes.get_type(carrier.uuid)) == nil
    end

    test "clearing a custom role's name is refused on save", %{conn: conn} do
      carrier = carrier!()
      {:ok, view, _html} = live(conn, "/en/admin/crm/settings/party-roles/#{carrier.uuid}/edit")

      html = view |> form("#party-role-form", party_role: %{name: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert PartyRoleTypes.name(PartyRoleTypes.get_type(carrier.uuid)) == "Carrier"
    end

    test "creating a role derives its key from the name and returns to the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new)

      html =
        view
        |> form("#party-role-form", party_role: %{name: "Freight forwarder"})
        |> render_change()

      assert html =~ "freight_forwarder"

      view
      |> form("#party-role-form", party_role: %{name: "Freight forwarder", badge: "badge-error"})
      |> render_submit()

      assert_redirect(view, Paths.party_roles())

      assert %{key: "freight_forwarder", badge: "badge-error", builtin: false} =
               PartyRoleTypes.get_type_by_key("freight_forwarder")

      assert_activity_logged("crm.party_role_type_created",
        metadata: %{"key" => "freight_forwarder"}
      )
    end

    test "the derived key follows the name until the admin types their own", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new)

      view |> form("#party-role-form", party_role: %{name: "Car"}) |> render_change()
      html = view |> form("#party-role-form", party_role: %{name: "Carrier"}) |> render_change()
      assert has_element?(view, ~s{input[name="party_role[key]"][value="carrier"]})
      refute html =~ ~s(value="car")

      view
      |> form("#party-role-form", party_role: %{name: "Carrier", key: "haul"})
      |> render_change()

      view
      |> form("#party-role-form", party_role: %{name: "Carrier OÜ", key: "haul"})
      |> render_submit()

      assert PartyRoleTypes.get_type_by_key("haul")
    end

    test "a name with no Latin letters asks for a key; a duplicate or reserved one is refused",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @new)

      html =
        view |> form("#party-role-form", party_role: %{name: "Перевозчик"}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert PartyRoleTypes.list_types() |> Enum.all?(& &1.builtin)

      html =
        view
        |> form("#party-role-form", party_role: %{name: "Перевозчик", key: "supplier"})
        |> render_submit()

      assert html =~ "is already taken"

      html =
        view
        |> form("#party-role-form", party_role: %{name: "Перевозчик", key: "trashed"})
        |> render_submit()

      assert html =~ "is reserved"
    end

    test "a missing name is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new)

      html =
        view |> form("#party-role-form", party_role: %{name: "", key: "ghost"}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute PartyRoleTypes.get_type_by_key("ghost")
    end

    test "editing keeps the key read-only and relabels a built-in everywhere", %{conn: conn} do
      supplier = PartyRoleTypes.get_type_by_key("supplier")
      {:ok, view, _html} = live(conn, "/en/admin/crm/settings/party-roles/#{supplier.uuid}/edit")

      assert has_element?(view, ~s{input[name="party_role[key]"][disabled]})
      assert has_element?(view, ~s{input[name="party_role[name]"][placeholder="Supplier"]})

      # A forged key in the payload goes nowhere.
      render_submit(view, "save", %{
        "party_role" => %{"name" => "Vendor", "key" => "vendor", "badge" => "badge-primary"}
      })

      assert_redirect(view, Paths.party_roles())
      supplier = PartyRoleTypes.get_type_by_key("supplier")
      assert supplier.key == "supplier"
      assert supplier.badge == "badge-primary"
      assert PartyRoleTypes.name(supplier) == "Vendor"
      refute PartyRoleTypes.get_type_by_key("vendor")

      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "supplier")
      {:ok, _view, html} = live(conn, "/en/admin/crm/companies")
      assert html =~ "Vendor"
    end

    test "an unknown role goes back to the list with a message", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to, flash: _}}} =
               live(conn, "/en/admin/crm/settings/party-roles/#{Ecto.UUID.generate()}/edit")

      assert to =~ "/admin/settings/crm"
    end

    test "the new role shows up, ticked, on the company form", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new)
      view |> form("#party-role-form", party_role: %{name: "Installer"}) |> render_submit()

      {:ok, view, _html} = live(conn, "/en/admin/crm/companies/new")
      assert has_element?(view, ~s{input[name="roles[]"][value="installer"]})
    end
  end

  defp pos(html, key) do
    {index, _} = :binary.match(html, ~s(id="party-role-#{key}"))
    index
  end
end
