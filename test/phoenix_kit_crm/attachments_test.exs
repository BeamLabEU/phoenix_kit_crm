defmodule PhoenixKitCRM.AttachmentsTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Attachments, Contacts}

  defp contact_fixture(name \\ "Avatar Contact") do
    {:ok, c} = Contacts.create_contact(%{"name" => name})
    c
  end

  # An image that lives in the contact's own Images folder.
  defp own_image!(c) do
    {:ok, images} = Attachments.ensure_folder(:contact, c.uuid, :images, nil)

    {:ok, owner} =
      Auth.register_user(%{
        "email" => "avatar-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    Repo.insert!(%StorageFile{
      original_file_name: "me.png",
      file_name: "me-#{System.unique_integer([:positive])}.png",
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: "c#{System.unique_integer([:positive])}",
      user_file_checksum: "u#{System.unique_integer([:positive])}",
      size: 1,
      status: "active",
      folder_uuid: images,
      user_uuid: owner.uuid
    })
  end

  describe "set_avatar/3 authorization" do
    test "refuses a file that isn't one of the record's own images" do
      c = contact_fixture()

      # No Images folder/file is linked to this contact, so a forged uuid is
      # rejected rather than blindly pointed at an arbitrary file in storage.
      assert {:error, :not_record_image} =
               Attachments.set_avatar(:contact, c, Ecto.UUID.generate())
    end

    test "refuses to set an avatar on a trashed record" do
      {:ok, trashed} = Contacts.trash_contact(contact_fixture())

      assert {:error, :record_trashed} =
               Attachments.set_avatar(:contact, trashed, Ecto.UUID.generate())
    end

    test "refuses when the record was trashed after it was loaded, and leaves no avatar" do
      c = contact_fixture()
      photo = own_image!(c)
      # Another session trashes it; `c` still reads active.
      {:ok, _} = Contacts.trash_contact(Repo.reload(c))

      assert {:error, :record_trashed} = Attachments.set_avatar(:contact, c, photo.uuid)
      assert Attachments.avatar_uuid(Repo.reload(c)) == nil
    end

    test "the record's own image becomes the avatar, keeping keys written since" do
      c = contact_fixture()
      {:ok, images} = Attachments.ensure_folder(:contact, c.uuid, :images, nil)

      {:ok, owner} =
        Auth.register_user(%{
          "email" => "avatar-#{System.unique_integer([:positive])}@example.test",
          "password" => "Sup3rSecret!24"
        })

      photo =
        Repo.insert!(%StorageFile{
          original_file_name: "me.png",
          file_name: "me-#{System.unique_integer([:positive])}.png",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: "c#{System.unique_integer([:positive])}",
          user_file_checksum: "u#{System.unique_integer([:positive])}",
          size: 1,
          status: "active",
          folder_uuid: images,
          user_uuid: owner.uuid
        })

      # Another session writes a metadata key after `c` was loaded.
      Repo.update!(Ecto.Changeset.change(c, metadata: %{"source" => "import"}))

      assert {:ok, updated} = Attachments.set_avatar(:contact, c, photo.uuid)
      assert updated.metadata == %{"source" => "import", "avatar_uuid" => photo.uuid}
      assert Attachments.avatar_uuid(Repo.reload(c)) == photo.uuid

      assert {:ok, cleared} = Attachments.clear_avatar(c, photo.uuid)
      assert cleared.metadata == %{"source" => "import"}
    end
  end
end
