defmodule PhoenixKitCRM.SettingsPermissionTest do
  @moduledoc """
  `crm.settings` — the settings page, the party-role form and the role pages
  (which list every holder of a role with their email) sit behind the
  sub-key, not the everyday `crm` key. Every write event re-checks it, the
  one-time backfill carries existing `crm` roles across, and only an
  eligible (non-system) role can be given a role page.
  """
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Test.SiteOwner

  # The site's Owner exists before the test's own users (see SiteOwner).
  setup do
    _owner = SiteOwner.ensure!()
    :ok
  end

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Role}
  alias PhoenixKitCRM.{PartyRoleTypes, RoleSettings, Test.Repo}

  @flag "crm_settings_backfilled"

  setup do
    {:ok, _} = PhoenixKitCRM.enable_system()
    :ok = ensure_crm_registered()
    :ok
  end

  defp unique, do: System.unique_integer([:positive])

  defp custom_role!(name \\ "Reseller") do
    Repo.insert!(%Role{name: "#{name} #{unique()}", is_system_role: false})
  end

  # Swap the mounted page's scope for `scope` — what core's live scope
  # refresh does when a role loses a grant while the page is open.
  defp swap_scope(view, scope) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      %{state | socket: Phoenix.Component.assign(socket, :phoenix_kit_current_scope, scope)}
    end)
  end

  describe "the sub-key" do
    test "is declared on the CRM permission and checked with Scope.can?/2" do
      assert %{sub_permissions: [%{key: "settings"}]} = PhoenixKitCRM.permission_metadata()
      assert PhoenixKitCRM.settings_permission() == "crm.settings"

      assert PhoenixKitCRM.can_change_settings?(settings_scope())
      refute PhoenixKitCRM.can_change_settings?(fake_scope())
      # A sub-key without its base is no grant.
      refute PhoenixKitCRM.can_change_settings?(fake_scope(permissions: ["crm.settings"]))
    end

    test "the settings tab and every role subtab carry it" do
      [tab] = PhoenixKitCRM.settings_tabs()
      assert tab.permission == "crm.settings"

      role_tab = PhoenixKitCRM.SidebarBootstrap.role_tab(custom_role!())
      assert role_tab.permission == "crm.settings"
    end
  end

  describe "the settings page" do
    test "the base key alone is refused at mount", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/en/admin/crm/settings")

      refute to =~ "/settings"
      assert flash["error"] =~ "permission"
    end

    test "a holder opens it", %{conn: conn} do
      {:ok, _view, html} = live(put_test_scope(conn, settings_scope()), "/en/admin/crm/settings")
      assert html =~ "Enable CRM"
    end

    test "every write event re-checks the sub-key", %{conn: conn} do
      {:ok, view, _html} = live(put_test_scope(conn, settings_scope()), "/en/admin/crm/settings")
      swap_scope(view, fake_scope())

      role = custom_role!()
      {:ok, carrier} = PartyRoleTypes.ensure("carrier", name: "Carrier")
      {:ok, custom} = PartyRoleTypes.ensure("x#{unique()}", name: "X")

      html = render_click(view, "toggle_role", %{"role_uuid" => role.uuid, "value" => "on"})
      assert html =~ "permission"
      refute RoleSettings.enabled?(role.uuid)

      render_click(view, "toggle", %{})
      assert PhoenixKitCRM.enabled?()

      render_click(view, "archive_party_role", %{"uuid" => custom.uuid})
      assert PartyRoleTypes.get_type(custom.uuid).status == "active"

      render_click(view, "delete_party_role", %{"uuid" => custom.uuid})
      assert PartyRoleTypes.get_type(custom.uuid)

      before = Enum.map(PartyRoleTypes.list_types(), & &1.uuid)

      render_click(view, "reorder_party_roles", %{
        "ordered_ids" => Enum.reverse([carrier.uuid | List.delete(before, carrier.uuid)])
      })

      assert Enum.map(PartyRoleTypes.list_types(), & &1.uuid) == before
    end
  end

  describe "the party-role form" do
    test "the base key alone is refused at mount", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, _}} =
               live(conn, "/en/admin/crm/settings/party-roles/new")
    end

    test "save re-checks the sub-key", %{conn: conn} do
      {:ok, view, _html} =
        live(put_test_scope(conn, settings_scope()), "/en/admin/crm/settings/party-roles/new")

      swap_scope(view, fake_scope())
      before = length(PartyRoleTypes.list_types())

      html =
        render_submit(view, "save", %{
          "party_role" => %{"name" => "Forwarder #{unique()}", "key" => "fwd#{unique()}"}
        })

      assert html =~ "permission"
      assert length(PartyRoleTypes.list_types()) == before
    end
  end

  describe "the role pages" do
    test "the base key alone is refused; the sub-key opens it", %{conn: conn} do
      role = custom_role!()
      {:ok, _} = RoleSettings.set_enabled(role.uuid, true)

      assert {:error, {:live_redirect, _}} =
               live(put_test_scope(conn, fake_scope()), "/en/admin/crm/roles/#{role.uuid}")

      assert {:ok, _view, _html} =
               live(put_test_scope(conn, settings_scope()), "/en/admin/crm/roles/#{role.uuid}")
    end

    test "a live patch to another role passes the same gate as a mount", %{conn: conn} do
      role = custom_role!()
      {:ok, _} = RoleSettings.set_enabled(role.uuid, true)
      sys = Repo.insert!(%Role{name: "Sys #{unique()}", is_system_role: true})
      off = custom_role!("Off")

      for target <- [sys, off] do
        {:ok, view, _html} =
          live(put_test_scope(conn, settings_scope()), "/en/admin/crm/roles/#{role.uuid}")

        assert {:error, {:live_redirect, _}} =
                 render_patch(view, "/en/admin/crm/roles/#{target.uuid}")
      end
    end

    test "a system role can never be given a page, even by a crafted event" do
      admin = Repo.insert!(%Role{name: "Sys #{unique()}", is_system_role: true})

      assert {:error, :not_eligible} = RoleSettings.set_enabled(admin.uuid, true)
      refute RoleSettings.enabled?(admin.uuid)
      # Turning a stray row off stays possible.
      assert {:ok, _} = RoleSettings.set_enabled(admin.uuid, false)
    end

    test "a stray enabled row for a system role is ignored", %{conn: conn} do
      admin = Repo.insert!(%Role{name: "Sys #{unique()}", is_system_role: true})

      Repo.insert!(%PhoenixKitCRM.RoleSetting{role_uuid: admin.uuid, enabled: true},
        on_conflict: :nothing
      )

      refute RoleSettings.enabled?(admin.uuid)
      refute Enum.any?(RoleSettings.list_enabled(), &(&1.uuid == admin.uuid))

      assert {:error, {:live_redirect, _}} =
               live(put_test_scope(conn, settings_scope()), "/en/admin/crm/roles/#{admin.uuid}")
    end
  end

  describe "while the CRM is switched off" do
    test "the settings page stays reachable, so the switch can turn it back on", %{conn: conn} do
      {:ok, _} = PhoenixKitCRM.disable_system()
      scope = settings_scope()
      assert PhoenixKitCRM.can_change_settings?(scope)
      assert PhoenixKitCRM.can_change_settings?(fake_scope(permissions: ["*"]))

      {:ok, view, _html} = live(put_test_scope(conn, scope), "/en/admin/crm/settings")
      render_click(view, "toggle", %{})
      assert PhoenixKitCRM.enabled?()
    end
  end

  describe "migrate_legacy/0 — the crm.settings backfill" do
    setup do
      Settings.update_setting(@flag, "false")
      :ok
    end

    test "grants the sub-key once to a role holding crm, and sets the flag" do
      role = custom_role!()
      {:ok, _} = Permissions.grant_permission(role.uuid, "crm", nil)

      assert :ok = PhoenixKitCRM.migrate_legacy()
      assert "crm.settings" in Permissions.get_permissions_for_role(role.uuid)
      assert Settings.get_setting(@flag) == "true"

      # Once only: a role granted crm afterwards gets the narrow meaning.
      later = custom_role!("Later")
      {:ok, _} = Permissions.grant_permission(later.uuid, "crm", nil)
      assert :ok = PhoenixKitCRM.migrate_legacy()
      refute "crm.settings" in Permissions.get_permissions_for_role(later.uuid)
    end

    test "a failing lookup leaves the flag unset, never reading as nobody holding crm" do
      role = custom_role!()
      {:ok, _} = Permissions.grant_permission(role.uuid, "crm", nil)

      assert {:error, :lookup_failed} =
               PhoenixKitCRM.backfill_settings_permission(holders: fn _ -> raise "db down" end)

      refute Settings.get_setting(@flag) == "true"
      # The next boot retries.
      assert :ok = PhoenixKitCRM.migrate_legacy()
      assert "crm.settings" in Permissions.get_permissions_for_role(role.uuid)
    end

    test "a role without crm is left alone" do
      role = custom_role!("Outsider")
      assert :ok = PhoenixKitCRM.migrate_legacy()
      refute "crm.settings" in Permissions.get_permissions_for_role(role.uuid)
    end

    test "a failed grant leaves the flag unset so the next boot retries" do
      role = custom_role!()
      {:ok, _} = Permissions.grant_permission(role.uuid, "crm", nil)

      assert {:error, {:settings_backfill_incomplete, [_ | _]}} =
               PhoenixKitCRM.backfill_settings_permission(
                 grant: fn _, _, _ -> {:error, :boom} end
               )

      refute Settings.get_setting(@flag) == "true"

      assert :ok = PhoenixKitCRM.migrate_legacy()
      assert "crm.settings" in Permissions.get_permissions_for_role(role.uuid)
      assert Settings.get_setting(@flag) == "true"
    end
  end

  describe "moderatable_resources/2 — comments' moderation scope" do
    test "a CRM holder moderates every contact, company and interaction comment" do
      scope = fake_scope()
      assert PhoenixKitCRM.moderatable_resources("crm_contact", scope) == :all
      assert PhoenixKitCRM.moderatable_resources("crm_company", scope) == :all

      assert PhoenixKitCRM.InteractionLinks.moderatable_resources("crm_interaction", scope) ==
               :all
    end

    test "anyone else moderates none, and an unknown type is none" do
      outsider = fake_scope(permissions: ["projects"])
      assert PhoenixKitCRM.moderatable_resources("crm_contact", outsider) == []
      assert PhoenixKitCRM.moderatable_resources("crm_company", outsider) == []

      assert PhoenixKitCRM.InteractionLinks.moderatable_resources("crm_interaction", outsider) ==
               []

      assert PhoenixKitCRM.moderatable_resources("post", fake_scope()) == []
      assert PhoenixKitCRM.moderatable_resources("crm_contact", nil) == []
    end

    test "with the CRM switched off, nobody moderates through it" do
      {:ok, _} = PhoenixKitCRM.disable_system()
      assert PhoenixKitCRM.moderatable_resources("crm_contact", fake_scope()) == []
    end
  end
end
