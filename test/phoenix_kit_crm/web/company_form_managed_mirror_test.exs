defmodule PhoenixKitCRM.Web.CompanyFormManagedMirrorTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.{Role, Roles}
  alias PhoenixKitCRM.{Companies, ManagedMirror, RoleSettings}
  alias PhoenixKitCRM.Test.Repo
  alias PhoenixKitCRM.Test.SiteOwner
  alias PhoenixKitCRM.Web.InteractionHelpers

  @moduletag skip: not ManagedMirror.supported?()

  setup %{conn: conn} do
    owner = SiteOwner.ensure!()
    token = Auth.generate_user_session_token(owner)

    {:ok, person} =
      Auth.register_user(%{
        "email" => "first-#{UUIDv7.generate()}@example.test",
        "password" => "Sup3rSecret!24"
      })

    {:ok, company} =
      Companies.create_company(%{"name" => "Shared inbox company", "email" => owner.email})

    Settings.update_boolean_setting("enable_organization_accounts", true)

    conn =
      conn
      |> put_test_scope(fake_scope(user_uuid: owner.uuid, email: owner.email))
      |> put_session(:user_token, token)

    %{conn: conn, owner: owner, token: token, person: person, company: company}
  end

  defp edit(conn, company), do: live(conn, "/en/admin/crm/companies/#{company.uuid}/edit")

  test "own administrator explicitly chooses a first manager and creates a shared-email organization",
       s do
    {:ok, view, html} = edit(s.conn, s.company)
    assert html =~ "Create as a managed organization"
    view |> form("#crm-mirror-manager-search", %{query: s.person.email}) |> render_submit()

    html =
      view
      |> form("#crm-mirror-managed-create", %{first_manager_uuid: s.person.uuid})
      |> render_submit()

    user = s.company.uuid |> Companies.get_company() |> Map.fetch!(:user_uuid) |> Auth.get_user()
    assert Map.get(user, :managed_by_members)
    assert Map.get(user, :contact_email) == s.owner.email
    assert html =~ s.owner.email
    refute html =~ user.email
    assert html =~ "Managed organization created and linked"
  end

  test "plain CRM account cannot enumerate manager candidates or forge the managed event", s do
    token = Auth.generate_user_session_token(s.person)

    conn =
      s.conn
      |> put_test_scope(
        fake_scope(user_uuid: s.person.uuid, email: s.person.email, roles: ["User"])
      )
      |> put_session(:user_token, token)

    {:ok, view, html} = edit(conn, s.company)
    refute html =~ "Create as a managed organization"
    render_submit(view, "mirror_manager_search", %{query: ""})

    render_submit(view, "mirror_create_managed", %{
      first_manager_uuid: s.person.uuid,
      manager_actor: "forged"
    })

    assert Companies.get_company(s.company.uuid).user_uuid == nil
  end

  test "borrowed administrator and stale revoked session cannot create", s do
    root = Auth.generate_user_session_token(s.person)
    borrowed = put_session(s.conn, :pk_session_accounts, [root, s.token])
    {:ok, view, html} = edit(borrowed, s.company)
    refute html =~ "Create as a managed organization"
    render_submit(view, "mirror_create_managed", %{first_manager_uuid: s.person.uuid})
    assert Companies.get_company(s.company.uuid).user_uuid == nil
    {:ok, own_view, _html} = edit(s.conn, s.company)
    Auth.delete_user_session_token(s.token)
    render_submit(own_view, "mirror_create_managed", %{first_manager_uuid: s.person.uuid})
    assert Companies.get_company(s.company.uuid).user_uuid == nil
  end

  test "turning organization accounts off refuses a mounted form", s do
    {:ok, view, _html} = edit(s.conn, s.company)
    Settings.update_boolean_setting("enable_organization_accounts", false)
    render_submit(view, "mirror_create_managed", %{first_manager_uuid: s.person.uuid})
    assert Companies.get_company(s.company.uuid).user_uuid == nil
  end

  test "inactive first managers are refused after search", s do
    {:ok, view, _html} = edit(s.conn, s.company)
    view |> form("#crm-mirror-manager-search", %{query: s.person.email}) |> render_submit()
    Repo.update!(Ecto.Changeset.change(s.person, is_active: false))
    render_submit(view, "mirror_create_managed", %{first_manager_uuid: s.person.uuid})
    assert Companies.get_company(s.company.uuid).user_uuid == nil
  end

  test "role listings and interaction shortcuts never use the managed login placeholder", s do
    actor = ManagedMirror.actor_from_session(get_session(s.conn))

    {:ok, {_company, user}} =
      Companies.create_mirror_user(s.company,
        managed: true,
        manager_actor: actor,
        first_manager_uuid: s.person.uuid
      )

    role = Repo.insert!(%Role{name: "Managed role #{UUIDv7.generate()}", is_system_role: false})
    {:ok, _} = Roles.assign_role(user, role.name)
    {:ok, _} = RoleSettings.set_enabled(role.uuid, true)
    {:ok, _} = PhoenixKitCRM.enable_system()
    conn = put_test_scope(s.conn, settings_scope(user_uuid: s.owner.uuid, email: s.owner.email))
    {:ok, _view, html} = live(conn, "/en/admin/crm/roles/#{role.uuid}")
    assert html =~ s.owner.email
    refute html =~ user.email

    assert InteractionHelpers.current_user_name(%{phoenix_kit_current_user: user}) ==
             user.organization_name
  end
end
