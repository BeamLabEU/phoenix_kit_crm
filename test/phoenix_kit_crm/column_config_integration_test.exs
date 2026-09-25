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

  test "update_columns/3 saves the offered ids, and an empty list goes back to the defaults" do
    user = create_user()
    role = {:role, Ecto.UUID.generate()}

    assert {:ok, _} = ColumnConfig.update_columns(user.uuid, role, ~w(organization_name email))
    assert ColumnConfig.get_columns(user.uuid, role) == ~w(email)

    assert {:ok, _} = ColumnConfig.update_columns(user.uuid, role, [])
    assert ColumnConfig.get_columns(user.uuid, role) == ColumnConfig.default_columns(role)
  end

  test "both tables keep their last column (the row link rides the first one)" do
    role = ColumnConfig.spec({:role, Ecto.UUID.generate()})
    assert PhoenixKitWeb.TableColumns.remove(["email"], "email", role) == ["email"]

    orgs = ColumnConfig.spec(:organizations)
    assert PhoenixKitWeb.TableColumns.remove(["email"], "email", orgs) == ["email"]
  end

  describe "V7" do
    defp v7_statement do
      Enum.find(Migrations.up_statements(), &(&1 =~ "phoenix_kit_user_view_prefs"))
    end

    defp copied?(done?) do
      Repo.query!("DELETE FROM phoenix_kit_settings WHERE key = 'crm_view_prefs_copied_at'")

      if done?,
        do:
          Repo.query!(
            "INSERT INTO phoenix_kit_settings (key, value, module) VALUES ('crm_view_prefs_copied_at', 'x', 'crm')"
          )
    end

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

      copied?(false)
      Repo.query!(v7_statement())

      assert ViewPrefs.get(a, "crm.organizations") == %{"columns" => ~w(email status)}
      assert ViewPrefs.get(a, "crm.role." <> role_uuid) == %{"columns" => ~w(full_name)}
      assert ViewPrefs.get(b, "crm.organizations") == %{"columns" => ~w(status)}
      assert ViewPrefs.get(c, "crm.organizations") == %{}
      assert ViewPrefs.get(c, "crm.role." <> role_uuid) == %{}
    end

    test "runs once, so a choice reset after the copy stays reset" do
      user = create_user()
      legacy!(user, "organizations", %{"columns" => ~w(email)})
      copied?(false)
      Repo.query!(v7_statement())

      # The admin's choice goes, row and all — so only the once-guard, not
      # the conflict clause, can keep a second run from copying it back.
      Repo.query!(
        "DELETE FROM phoenix_kit_user_view_prefs WHERE user_uuid = $1::text::uuid AND key = 'crm.organizations'",
        [user.uuid]
      )

      Repo.query!(v7_statement())
      assert ViewPrefs.get(user, "crm.organizations") == %{}
    end

    test "V7 writes the keys the runtime reads" do
      uuid = Ecto.UUID.generate()
      assert ColumnConfig.view_key(:organizations) == "crm.organizations"
      assert ColumnConfig.view_key({:role, uuid}) == "crm.role." <> uuid
      # The SQL builds the same two shapes from the legacy scope column.
      assert v7_statement() =~ "'crm.' || replace(v.scope, ':', '.')"
      assert v7_statement() =~ "v.scope = 'organizations' OR v.scope LIKE 'role:%'"
    end

    # The statement itself, replayed after the table appeared, still copies:
    # this pins the guard's shape, not when the chain replays it (only while
    # a later CRM version is pending).
    test "a replay of the statement copies once the table is there" do
      user = create_user()
      legacy!(user, "organizations", %{"columns" => ~w(email)})
      Repo.query!("COMMENT ON TABLE public.phoenix_kit_crm_contacts IS 'crm_schema:7'")
      copied?(false)

      Repo.query!(v7_statement())
      assert ViewPrefs.get(user, "crm.organizations") == %{"columns" => ~w(email)}
    end
  end
end
