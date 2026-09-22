defmodule PhoenixKitCRM.ColumnConfigIntegrationTest do
  @moduledoc """
  Each admin's CRM column choice is kept by core's per-user view
  preferences, per role page and for Organizations; V7 brings the choices
  saved in CRM's old table across once.
  """
  use PhoenixKitCRM.DataCase

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.ViewPrefs
  alias PhoenixKitCRM.{ColumnConfig, Migrations, Test.Repo}

  defp create_user do
    Repo.insert!(%User{
      email: "crm_test_#{System.unique_integer([:positive])}@example.com",
      hashed_password: "fake_hash_not_used_in_tests",
      is_active: true
    })
  end

  test "an admin with no choice sees the scope's defaults" do
    user = create_user()
    role = {:role, Ecto.UUID.generate()}

    assert ColumnConfig.get_columns(user.uuid, :organizations) ==
             ColumnConfig.default_columns(:organizations)

    assert ColumnConfig.get_columns(user.uuid, role) == ColumnConfig.default_columns(role)
  end

  test "a choice is kept per scope, skipping ids that scope does not offer" do
    user = create_user()
    role = {:role, Ecto.UUID.generate()}

    {:ok, _} =
      ViewPrefs.put(user, ColumnConfig.view_key(:organizations), %{
        "columns" => ~w(status organization_name)
      })

    {:ok, _} =
      ViewPrefs.put(user, ColumnConfig.view_key(role), %{"columns" => ~w(organization_name email)})

    assert ColumnConfig.get_columns(user.uuid, :organizations) == ~w(status organization_name)
    # organization_name is not a role page's column.
    assert ColumnConfig.get_columns(user.uuid, role) == ~w(email)
  end

  describe "V7" do
    defp v7_statement do
      Enum.find(Migrations.up_statements(), &(&1 =~ "phoenix_kit_user_view_prefs"))
    end

    defp set_marker(version),
      do:
        Repo.query!("COMMENT ON TABLE public.phoenix_kit_crm_contacts IS 'crm_schema:#{version}'")

    defp legacy!(user, scope, config) do
      Repo.query!(
        "INSERT INTO phoenix_kit_crm_user_role_view (user_uuid, scope, view_config) VALUES ($1::text::uuid, $2, $3)",
        [user.uuid, scope, config]
      )
    end

    test "copies each saved list once, keeps a choice already in core, and skips empty ones" do
      [a, b, c] = [create_user(), create_user(), create_user()]
      role_uuid = Ecto.UUID.generate()

      legacy!(a, "organizations", %{"columns" => ~w(email status)})
      legacy!(a, "role:" <> role_uuid, %{"columns" => ~w(full_name)})
      legacy!(b, "organizations", %{"columns" => ~w(email)})
      {:ok, _} = ViewPrefs.put(b, "crm.organizations", %{"columns" => ~w(status)})
      legacy!(c, "organizations", %{"columns" => []})
      # A malformed row is skipped, not an error that aborts the migration.
      legacy!(c, "role:" <> role_uuid, %{"columns" => "email"})

      set_marker(6)
      Repo.query!(v7_statement())

      assert ViewPrefs.get(a, "crm.organizations") == %{"columns" => ~w(email status)}
      assert ViewPrefs.get(a, "crm.role." <> role_uuid) == %{"columns" => ~w(full_name)}
      assert ViewPrefs.get(b, "crm.organizations") == %{"columns" => ~w(status)}
      assert ViewPrefs.get(c, "crm.organizations") == %{}
      assert ViewPrefs.get(c, "crm.role." <> role_uuid) == %{}
    end

    test "does nothing once the chain is at V7, so a reset choice stays reset" do
      user = create_user()
      legacy!(user, "organizations", %{"columns" => ~w(email)})

      set_marker(7)
      Repo.query!(v7_statement())

      assert ViewPrefs.get(user, "crm.organizations") == %{}
    end
  end
end
