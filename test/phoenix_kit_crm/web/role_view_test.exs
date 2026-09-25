defmodule PhoenixKitCRM.Web.RoleViewTest do
  @moduledoc """
  The role page's "CRM contact" column reads a page-wide map that is loaded
  only while the column is on screen. Saving the column set does not re-run
  `handle_params/3`, so ticking the column on used to render "—" for every
  row — including portal users that DO have a linked contact — until a
  reload.
  """
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.{Auth, Role, Roles, ViewPrefs}
  alias PhoenixKitCRM.{ColumnConfig, Contacts, RoleSettings, Test.Repo}

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCRM.enable_system()

    # Saving a column set writes a row keyed on the viewer's user uuid, so the
    # viewer has to be a real user, not the fake scope's random uuid.
    {:ok, admin} =
      Auth.register_user(%{
        "email" => "admin-#{unique()}@example.test",
        "password" => "Sup3rSecret!24"
      })

    scope = fake_scope(user_uuid: admin.uuid, email: admin.email)
    {:ok, conn: put_test_scope(conn, scope), scope: scope, admin: admin}
  end

  defp unique, do: System.unique_integer([:positive])

  defp crm_role_fixture do
    role = Repo.insert!(%Role{name: "Reseller #{unique()}", is_system_role: false})
    {:ok, _} = RoleSettings.set_enabled(role.uuid, true)
    role
  end

  defp portal_user_fixture(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "portal-#{unique()}@example.test",
        "password" => "Sup3rSecret!24"
      })

    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  test "ticking the CRM contact column on shows the linked contacts without a reload",
       %{conn: conn, admin: admin} do
    role = crm_role_fixture()
    user = portal_user_fixture(role)

    {:ok, contact} = Contacts.create_contact(%{"name" => "Linked Person"})
    {:ok, contact} = Contacts.link_user(contact, user.uuid)

    {:ok, view, html} = live(conn, "/en/admin/crm/roles/#{role.uuid}")

    # The column is not a default, so nothing about the contact is on screen.
    refute html =~ contact.uuid

    view |> element(~s(button[phx-click="show_column_modal"])) |> render_click()

    html =
      view
      |> element(~s(button[phx-click="add_column"][phx-value-column_id="crm_contact"]))
      |> render_click()

    # The CRM contact cell links the contact rather than showing "—".
    assert html =~ ~r{<td[^>]*><a href="/en/admin/crm/contacts/#{contact.uuid}"}

    # ...and the choice is the admin's, saved for the next visit.
    assert "crm_contact" in ViewPrefs.get(admin, ColumnConfig.view_key({:role, role.uuid}))[
             "columns"
           ]
  end

  test "the trail is CRM / <role name> — the module is the section, the role is the page",
       %{conn: conn} do
    role = crm_role_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/crm/roles/#{role.uuid}")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm']", "CRM")
    assert has_element?(view, "#test-page-title", role.name)
    refute has_element?(view, "#test-page-title", "CRM —")
  end
end
