defmodule PhoenixKitCRM.AccountGuardTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKit.Users.{Auth, Roles}
  alias PhoenixKitCRM.AccountGuard
  alias PhoenixKitCRM.Test.SiteOwner

  setup do
    SiteOwner.ensure!()

    {:ok, user} =
      Auth.register_user(%{
        "email" => "placeholder-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24",
        "custom_fields" => %{"source" => "crm_contact"}
      })

    user = user |> change() |> force_change(:confirmed_at, nil) |> Repo.update!()
    %{user: user}
  end

  test "blank fills preserve fields populated since the caller read the account", %{user: user} do
    {:ok, _} = Auth.update_user_profile(user, %{first_name: "Newer"})

    assert {:ok, updated} =
             AccountGuard.update_placeholder_profile(
               user,
               %{first_name: "Old", last_name: "Filled"},
               only_blank: true
             )

    assert updated.first_name == "Newer"
    assert updated.last_name == "Filled"
    assert Auth.get_user(user.uuid).first_name == "Newer"
  end

  test "blank fills leave an account claimed since the caller's read alone", %{user: user} do
    claimed = user |> change(confirmed_at: DateTime.utc_now(:second)) |> Repo.update!()

    assert {:ok, updated} =
             AccountGuard.update_placeholder_profile(user, %{first_name: "Changed"},
               only_blank: true
             )

    assert updated.confirmed_at == claimed.confirmed_at
    assert Auth.get_user(user.uuid).first_name == claimed.first_name
  end

  test "the current source decides whether the CRM owns the placeholder", %{user: user} do
    user |> change(custom_fields: %{"source" => "staff_placeholder"}) |> Repo.update!()

    assert {:ok, updated} =
             AccountGuard.update_placeholder_profile(user, %{first_name: "Changed"})

    assert updated.custom_fields["source"] == "staff_placeholder"
    assert Auth.get_user(user.uuid).first_name == user.first_name
  end

  test "an unclaimed placeholder promoted to Admin is never written", %{user: user} do
    {:ok, _} = Roles.assign_role(user, "Admin")

    assert {:ok, _} = AccountGuard.update_placeholder_profile(user, %{first_name: "Changed"})
    assert Auth.get_user(user.uuid).first_name == user.first_name
  end

  test "a deleted account returns an error", %{user: user} do
    Repo.delete!(user)
    assert {:error, :user_not_found} = AccountGuard.update_placeholder_profile(user, %{})
  end
end
