defmodule PhoenixKitCRM.Web.SettingsLiveTest do
  @moduledoc """
  Toggling a role's CRM access re-registers the role subtabs in core's
  dashboard registry, but the sidebar in this page's layout reads the
  registry only when it renders and none of its assigns change on the
  toggle — the new (or removed) subtab stayed invisible until the operator
  navigated away. The registry broadcasts badge updates only, so the page
  remounts itself instead.
  """
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Role
  alias PhoenixKitCRM.{RoleSettings, Test.Repo}

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCRM.enable_system()
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  test "toggling a role's access saves it and remounts the page so the sidebar re-reads the registry",
       %{conn: conn} do
    role = Repo.insert!(%Role{name: "Reseller #{System.unique_integer([:positive])}"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/settings")

    assert {:error, {:live_redirect, %{to: to}}} =
             render_click(view, "toggle_role", %{"role_uuid" => role.uuid, "value" => "on"})

    assert to =~ "/admin/settings/crm"
    assert RoleSettings.enabled?(role.uuid)
    # Granting a role CRM access was the module's only unlogged mutation.
    assert_activity_logged("crm.role_access_enabled", resource_uuid: role.uuid)
  end

  test "an enabled role row carries the portal info the overview used to show — user count and the portal link",
       %{conn: conn} do
    role = Repo.insert!(%Role{name: "Sales #{System.unique_integer([:positive])}"})
    {:ok, _} = RoleSettings.set_enabled(role.uuid, true)

    {:ok, view, html} = live(conn, "/en/admin/crm/settings")

    assert html =~ "0 users"
    assert has_element?(view, ~s{a[href="/en/admin/crm/role/#{role.uuid}"]}, "Open portal view")
  end

  test "a disabled role row offers no portal link — there is no portal view to open", %{
    conn: conn
  } do
    role = Repo.insert!(%Role{name: "Dormant #{System.unique_integer([:positive])}"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/settings")

    refute has_element?(view, ~s{a[href="/en/admin/crm/role/#{role.uuid}"]})
  end
end
