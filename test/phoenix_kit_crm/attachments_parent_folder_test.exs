defmodule PhoenixKitCRM.AttachmentsParentFolderTest do
  use PhoenixKitCRM.DataCase, async: false

  import Ecto.Query
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Attachments

  # phoenix_kit_files.user_uuid carries an fk_files_user_uuid constraint, so a
  # raw insert (bypassing the upload pipeline) needs a real user row.
  defp file_owner_uuid do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "attachments-parent-folder-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    user.uuid
  end

  defmodule Hook do
    def parent(:company, _actor, _subject), do: {:ok, Process.get(:companies)}
    def parent(:contact, _actor, _subject), do: {:ok, Process.get(:contacts)}
    def parent(:interaction, _actor, _subject), do: {:ok, Process.get(:interactions)}
    def parent(_, _, _), do: nil
  end

  # A parent that depends on the actor (and reports the subject it was given).
  # Reads run without an actor, so resolution must not depend on the hook.
  defmodule ActorHook do
    def parent(kind, actor, subject) do
      send(self(), {:parent_hook, kind, actor, subject})
      if actor, do: {:ok, Process.get({:parent_for, actor})}
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_crm, :attachments_parent_folder) end)

    {:ok, companies} =
      Storage.create_folder(%{name: "Companies-#{System.unique_integer([:positive])}"})

    {:ok, contacts} =
      Storage.create_folder(%{name: "Contacts-#{System.unique_integer([:positive])}"})

    {:ok, interactions} =
      Storage.create_folder(%{name: "Interactions-#{System.unique_integer([:positive])}"})

    Process.put(:companies, companies.uuid)
    Process.put(:contacts, contacts.uuid)
    Process.put(:interactions, interactions.uuid)
    %{companies: companies, contacts: contacts, interactions: interactions}
  end

  defp hook_on,
    do: Application.put_env(:phoenix_kit_crm, :attachments_parent_folder, {Hook, :parent})

  test "without config folders are created at root" do
    uuid = Ecto.UUID.generate()
    assert {:ok, fuuid} = Attachments.ensure_folder(:company, uuid, :files, nil)
    assert Repo.get!(Folder, fuuid).parent_uuid == nil
  end

  test "with config the root folder is created under the parent and Images under it", %{
    companies: c
  } do
    hook_on()
    uuid = Ecto.UUID.generate()
    assert {:ok, root} = Attachments.ensure_folder(:company, uuid, :files, nil)
    assert Repo.get!(Folder, root).parent_uuid == c.uuid
    assert {:ok, images} = Attachments.ensure_folder(:company, uuid, :images, nil)
    assert Repo.get!(Folder, images).parent_uuid == root
    assert Attachments.folder_uuid(:company, uuid, :files) == root
    assert Attachments.folder_uuid(:company, uuid, :images) == images
  end

  test "a folder created at root before the hook is still found (no twin)", %{contacts: _} do
    uuid = Ecto.UUID.generate()
    {:ok, legacy} = Attachments.ensure_folder(:contact, uuid, :files, nil)
    hook_on()
    assert Attachments.folder_uuid(:contact, uuid, :files) == legacy
    assert {:ok, ^legacy} = Attachments.ensure_folder(:contact, uuid, :files, nil)
    assert Repo.aggregate(from(f in Folder, where: f.name == ^"crm-contact-#{uuid}"), :count) == 1
  end

  test "a host's own root-level Images folder is never used as a record's Images folder" do
    {:ok, host_images} = Storage.create_folder(%{name: "Images"})
    hook_on()
    uuid = Ecto.UUID.generate()

    assert {:ok, images} = Attachments.ensure_folder(:company, uuid, :images, nil)
    refute images == host_images.uuid

    assert Repo.get!(Folder, images).parent_uuid ==
             Attachments.folder_uuid(:company, uuid, :files)

    assert Attachments.folder_uuid(:company, uuid, :images) == images
  end

  test "an actor-dependent parent: reads without an actor find the folder, no actor twins it", %{
    companies: a_parent,
    contacts: b_parent
  } do
    Application.put_env(:phoenix_kit_crm, :attachments_parent_folder, {ActorHook, :parent})
    [actor_a, actor_b] = [file_owner_uuid(), file_owner_uuid()]
    Process.put({:parent_for, actor_a}, a_parent.uuid)
    Process.put({:parent_for, actor_b}, b_parent.uuid)
    uuid = Ecto.UUID.generate()

    assert {:ok, images} = Attachments.ensure_folder(:contact, uuid, :images, actor_a)
    root = Repo.get!(Folder, images).parent_uuid
    assert Repo.get!(Folder, root).parent_uuid == a_parent.uuid

    assert Attachments.folder_uuid(:contact, uuid, :files) == root
    assert Attachments.folder_uuid(:contact, uuid, :images) == images
    assert {:ok, ^root} = Attachments.ensure_folder(:contact, uuid, :files, actor_b)
    assert {:ok, ^images} = Attachments.ensure_folder(:contact, uuid, :images, actor_b)
    assert Repo.aggregate(from(f in Folder, where: f.name == ^"crm-contact-#{uuid}"), :count) == 1

    assert :ok = Attachments.purge_media(:contact, uuid)
    assert Repo.get(Folder, root) == nil

    # The hook is told which record it is placing.
    assert_received {:parent_hook, :contact, ^actor_a, ^uuid}
  end

  test "purge_media deletes a nested folder" do
    hook_on()
    uuid = Ecto.UUID.generate()
    {:ok, root} = Attachments.ensure_folder(:company, uuid, :images, nil)
    assert :ok = Attachments.purge_media(:company, uuid)
    assert Repo.get(Folder, root) == nil
  end

  test "interaction folders: nested create, list mixed root/nested", %{interactions: i} do
    legacy_id = Ecto.UUID.generate()
    {:ok, legacy_folder} = Attachments.ensure_interaction_folder(legacy_id, nil)
    hook_on()
    nested_id = Ecto.UUID.generate()
    {:ok, nested_folder} = Attachments.ensure_interaction_folder(nested_id, nil)
    assert Repo.get!(Folder, nested_folder).parent_uuid == i.uuid
    assert Attachments.interaction_folder_uuid(legacy_id) == legacy_folder

    # one file in each
    for {f, n} <- [{legacy_folder, "a"}, {nested_folder, "b"}] do
      Repo.insert!(%PhoenixKit.Modules.Storage.File{
        original_file_name: "#{n}.png",
        file_name: "#{n}-#{System.unique_integer([:positive])}.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: "c#{System.unique_integer([:positive])}",
        user_file_checksum: "u#{System.unique_integer([:positive])}",
        size: 1,
        status: "active",
        folder_uuid: f,
        user_uuid: file_owner_uuid()
      })
    end

    files = Attachments.list_files_by_interaction([legacy_id, nested_id])
    assert map_size(files) == 2
  end

  test "an interaction with a root twin AND a nested folder lists only the nested folder's files",
       %{interactions: i} do
    id = Ecto.UUID.generate()
    {:ok, root_folder} = Attachments.ensure_interaction_folder(id, nil)
    hook_on()
    {:ok, nested} = Storage.create_folder(%{name: "crm-interaction-#{id}", parent_uuid: i.uuid})

    for {f, n} <- [{root_folder, "root"}, {nested.uuid, "nested"}] do
      Repo.insert!(%PhoenixKit.Modules.Storage.File{
        original_file_name: "#{n}.png",
        file_name: "#{n}-#{System.unique_integer([:positive])}.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: "c#{System.unique_integer([:positive])}",
        user_file_checksum: "u#{System.unique_integer([:positive])}",
        size: 1,
        status: "active",
        folder_uuid: f,
        user_uuid: file_owner_uuid()
      })
    end

    assert %{^id => [%{original_file_name: "nested.png"}]} =
             Attachments.list_files_by_interaction([id])
  end

  test "a contact folder trashed in the media browser is never uploaded into again" do
    uuid = Ecto.UUID.generate()
    {:ok, old} = Attachments.ensure_folder(:contact, uuid, :files, nil)
    {:ok, _} = Storage.trash_folder(Repo.get!(Folder, old))

    assert Attachments.folder_uuid(:contact, uuid, :files) == nil
    assert {:ok, new} = Attachments.ensure_folder(:contact, uuid, :files, nil)
    refute new == old
  end

  test "purge_media removes every folder named after the record, trashed twins included" do
    uuid = Ecto.UUID.generate()
    name = Attachments.root_folder_name(:contact, uuid)
    {:ok, trashed} = Storage.create_folder(%{name: name})
    {:ok, _} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: name})

    assert :ok = Attachments.purge_media(:contact, uuid)
    refute Repo.get(Folder, trashed.uuid)
    refute Repo.get(Folder, live.uuid)
  end
end
