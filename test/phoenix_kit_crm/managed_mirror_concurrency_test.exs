defmodule PhoenixKitCRM.ManagedMirrorConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{Companies, ManagedMirror}
  alias PhoenixKitCRM.Schemas.Company
  alias PhoenixKitCRM.Test.Repo
  alias PhoenixKitCRM.Test.SiteOwner

  @moduletag :integration
  @moduletag skip: not ManagedMirror.supported?()

  test "concurrent managed creation locks the company and creates only one account" do
    Sandbox.mode(Repo, :auto)
    owner = SiteOwner.ensure!()
    token = Auth.generate_user_session_token(owner)
    actor = ManagedMirror.actor_from_session(%{"user_token" => token})
    Settings.update_boolean_setting("enable_organization_accounts", true)

    {:ok, person} =
      Auth.register_user(%{
        "email" => "race-#{UUIDv7.generate()}@example.test",
        "password" => "Sup3rSecret!24"
      })

    name = "Concurrent managed #{UUIDv7.generate()}"
    {:ok, company} = Companies.create_company(%{"name" => name, "email" => person.email})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      users = Repo.all(from(u in User, where: u.organization_name == ^name, select: u.uuid))
      Repo.delete_all(from(c in Company, where: c.uuid == ^company.uuid))
      ids = [owner.uuid, person.uuid | users]
      Repo.delete_all(from(u in User, where: u.uuid in ^ids))
      Settings.update_boolean_setting("enable_organization_accounts", false)
      Sandbox.mode(Repo, :manual)
    end)

    parent = self()
    opts = [managed: true, manager_actor: actor, first_manager_uuid: person.uuid]

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = Companies.create_mirror_user(company, opts)
          send(parent, {:created, result})

          receive do
            :commit -> result
          after
            5_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive {:created, {:ok, {linked, user}}}, 3_000

    second =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, backend})
          Companies.create_mirror_user(company, opts)
        end)
      end)

    assert_receive {:backend, backend}, 1_000
    assert_blocked(backend)
    send(first.pid, :commit)
    assert {:ok, _} = Task.await(first, 5_000)
    assert {:error, :already_linked} = Task.await(second, 5_000)
    assert linked.user_uuid == user.uuid
    assert Companies.get_company(company.uuid).user_uuid == user.uuid
    assert Repo.aggregate(from(u in User, where: u.organization_name == ^name), :count) == 1
  end

  defp assert_blocked(backend, remaining \\ 200)
  defp assert_blocked(_backend, 0), do: flunk("second creation did not wait for the company lock")

  defp assert_blocked(backend, remaining) do
    %{rows: rows} =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend])

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(10)
      assert_blocked(backend, remaining - 1)
    end
  end
end
