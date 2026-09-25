defmodule PhoenixKitCRM.ServerOwnedMetadataTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Companies, Contacts}

  defp contact! do
    {:ok, c} = Contacts.create_contact(%{"name" => "Meta #{System.unique_integer([:positive])}"})
    c
  end

  test "a metadata map from params can neither set nor clear the avatar pointer" do
    c = contact!()
    # The pointer is written behind the struct's back, as `set_avatar/3` does.
    Repo.update!(Ecto.Changeset.change(c, metadata: %{"avatar_uuid" => "own"}))

    # Spoof it, in both key spellings, alongside a legitimate host key.
    assert {:ok, updated} =
             Contacts.update_contact(c, %{
               "metadata" => %{
                 "avatar_uuid" => "forged",
                 :avatar_uuid => "forged",
                 "source" => "import"
               }
             })

    assert updated.metadata == %{"avatar_uuid" => "own", "source" => "import"}

    # Leaving the key out does not clear it either.
    assert {:ok, updated} =
             Contacts.update_contact(updated, %{"metadata" => %{"source" => "crm"}})

    assert updated.metadata == %{"avatar_uuid" => "own", "source" => "crm"}
    assert Repo.reload(c).metadata == %{"avatar_uuid" => "own", "source" => "crm"}
  end

  test "a new record cannot be created with a server-owned key" do
    assert {:ok, c} =
             Contacts.create_contact(%{
               "name" => "Meta new",
               "metadata" => %{"trashed_from_status" => "active", "note" => "x"}
             })

    assert c.metadata == %{"note" => "x"}
  end

  test "the same rule holds for companies" do
    {:ok, co} =
      Companies.create_company(%{"name" => "Meta Co #{System.unique_integer([:positive])}"})

    Repo.update!(Ecto.Changeset.change(co, metadata: %{"avatar_uuid" => "own"}))

    assert {:ok, updated} =
             Companies.update_company(co, %{"metadata" => %{"avatar_uuid" => "forged"}})

    assert updated.metadata == %{"avatar_uuid" => "own"}
  end
end
