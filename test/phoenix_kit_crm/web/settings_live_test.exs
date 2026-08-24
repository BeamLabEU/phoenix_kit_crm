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
  end
end
