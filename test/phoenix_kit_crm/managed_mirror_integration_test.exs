defmodule PhoenixKitCRM.ManagedMirrorIntegrationTest do
  use PhoenixKitCRM.DataCase, async: true

  import Ecto.Query

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{Companies, ManagedMirror, Mirror}
  alias PhoenixKitCRM.Test.Repo
  alias PhoenixKitCRM.Test.SiteOwner

  @moduletag skip: not ManagedMirror.supported?()

  setup do
    owner = SiteOwner.ensure!()
    token = Auth.generate_user_session_token(owner)
    actor = ManagedMirror.actor_from_session(%{"user_token" => token})
    Settings.update_boolean_setting("enable_organization_accounts", true)

    {:ok, person} =
      Auth.register_user(%{
        "email" => "first-#{UUIDv7.generate()}@example.test",
        "password" => "Sup3rSecret!24"
      })

    %{actor: actor, owner: owner, person: person, token: token}
  end

  defp company(attrs \\ %{}) do
    {:ok, company} =
      Companies.create_company(
        Map.merge(%{"name" => "Managed company", "email" => "shared@example.test"}, attrs)
      )

    company
  end

  test "explicit managed creation is atomic and uses a shared contact address", s do
    company = company(%{"email" => s.person.email})

    assert {:ok, {linked, user}} =
             Companies.create_mirror_user(company,
               managed: true,
               manager_actor: s.actor,
               first_manager_uuid: s.person.uuid
             )

    assert linked.user_uuid == user.uuid
    assert Map.get(user, :managed_by_members)
    assert Map.get(user, :contact_email) == s.person.email
    assert user.email != s.person.email
    assert user.confirmed_at
    assert user.created_by_uuid == s.owner.uuid
    assert user.custom_fields["source"] == "crm_company"
    refute Mirror.placeholder_user?(user)
    assert Auth.get_user_by_email(s.person.email).uuid == s.person.uuid

    assert Repo.one(
             from(m in "phoenix_kit_organization_managers",
               where: field(m, :organization_uuid) == type(^user.uuid, :binary_id),
               select: type(field(m, :user_uuid), :binary_id)
             )
           ) == s.person.uuid
  end

  test "a required first manager and a real own-admin session cannot be forged", s do
    company = company()

    for opts <- [
          [manager_actor: s.owner, first_manager_uuid: s.person.uuid],
          [manager_actor: s.actor],
          [manager_actor: s.actor, first_manager_uuid: "forged"]
        ] do
      assert {:error, _} = Companies.create_mirror_user(company, [managed: true] ++ opts)
    end

    assert Companies.get_company(company.uuid).user_uuid == nil

    assert Repo.aggregate(
             from(u in User, where: u.organization_name == "Managed company"),
             :count
           ) == 0
  end

  test "stale company snapshots cannot mint and orphan another account", s do
    original = company()

    assert {:ok, {_, user}} =
             Companies.create_mirror_user(original,
               managed: true,
               manager_actor: s.actor,
               first_manager_uuid: s.person.uuid
             )

    assert {:error, :already_linked} =
             Companies.create_mirror_user(original,
               managed: true,
               manager_actor: s.actor,
               first_manager_uuid: s.person.uuid
             )

    assert Repo.aggregate(
             from(u in User, where: u.organization_name == "Managed company"),
             :count
           ) == 1

    assert Companies.get_company(original.uuid).user_uuid == user.uuid
  end

  test "switch off and revoked administrator refuse the explicit path", s do
    company = company()
    Settings.update_boolean_setting("enable_organization_accounts", false)

    assert {:error, :forbidden} =
             Companies.create_mirror_user(company,
               managed: true,
               manager_actor: s.actor,
               first_manager_uuid: s.person.uuid
             )

    Settings.update_boolean_setting("enable_organization_accounts", true)
    Auth.delete_user_session_token(s.token)

    assert {:error, :forbidden} =
             Companies.create_mirror_user(company,
               managed: true,
               manager_actor: s.actor,
               first_manager_uuid: s.person.uuid
             )
  end

  test "reverse mirroring adopts by contact email rather than placeholder", s do
    source = company(%{"name" => "Old name"})

    {:ok, {_linked, user}} =
      Companies.create_mirror_user(source,
        managed: true,
        manager_actor: s.actor,
        first_manager_uuid: s.person.uuid
      )

    {:ok, _} = Companies.disconnect_user(Companies.get_company(source.uuid))

    {:ok, _} =
      Companies.update_company(Companies.get_company(source.uuid), %{
        "name" => "Different stored name"
      })

    assert {:ok, linked} = Companies.create_from_user(user)
    assert linked.uuid == source.uuid
    assert linked.email == Map.get(user, :contact_email)
    assert linked.user_uuid == user.uuid
  end

  test "claimed managed profiles stay read-only under legacy mirror resolution", s do
    original = company()

    {:ok, {_linked, user}} =
      Companies.create_mirror_user(original,
        managed: true,
        manager_actor: s.actor,
        first_manager_uuid: s.person.uuid
      )

    {:ok, _} = Companies.disconnect_user(Companies.get_company(original.uuid))
    current = Companies.get_company(original.uuid)

    assert {:ok, {_linked, unchanged}} =
             Companies.apply_mirror_resolution(current, user, %{
               crm: %{},
               user: %{contact_email: "injected@example.com", email: "bad@example.com"}
             })

    assert Map.get(unchanged, :contact_email) == Map.get(user, :contact_email)
    assert unchanged.email == user.email
  end

  test "email collisions never trigger an automatic managed fallback or grant", s do
    company = company(%{"email" => s.owner.email})
    assert {:error, _} = Companies.create_mirror_user(company)
    assert Companies.get_company(company.uuid).user_uuid == nil

    assert {:ok, {_linked, user}} =
             Companies.create_mirror_user(company,
               managed: true,
               manager_actor: s.actor,
               first_manager_uuid: s.person.uuid
             )

    managers =
      Repo.all(
        from(m in "phoenix_kit_organization_managers",
          where: field(m, :organization_uuid) == type(^user.uuid, :binary_id),
          select: type(field(m, :user_uuid), :binary_id)
        )
      )

    assert managers == [s.person.uuid]
    refute s.owner.uuid in managers
  end

  test "caller rollback restores the unlinked company and removes the new account", s do
    company = company()

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Companies.create_mirror_user(company,
                          managed: true,
                          manager_actor: s.actor,
                          first_manager_uuid: s.person.uuid
                        )

               Repo.rollback(:cancelled)
             end)

    assert Companies.get_company(company.uuid).user_uuid == nil
    refute Repo.exists?(from(u in User, where: u.organization_name == "Managed company"))
  end

  test "invalid contact addresses cannot leave an account or grant behind", s do
    company = company(%{"email" => "invalid@organization.invalid"})

    assert {:error, %Ecto.Changeset{}} =
             Companies.create_mirror_user(company,
               managed: true,
               manager_actor: s.actor,
               first_manager_uuid: s.person.uuid
             )

    assert Companies.get_company(company.uuid).user_uuid == nil
    refute Repo.exists?(from(u in User, where: u.organization_name == "Managed company"))
  end
end
