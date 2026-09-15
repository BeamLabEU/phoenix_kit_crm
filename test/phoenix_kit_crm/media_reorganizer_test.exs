defmodule PhoenixKitCRM.MediaReorganizerTest do
  use PhoenixKitCRM.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Contacts, Interactions, MediaReorganizer}

  defmodule Hook do
    def parent(:contact, _actor, _subject), do: {:ok, Process.get(:target_folder)}
    def parent(:company, _actor, _subject), do: {:ok, Process.get(:target_folder)}
    def parent(:interaction, _actor, _subject), do: {:ok, Process.get(:target_folder)}
    def parent(_, _, _), do: nil
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_crm, :attachments_parent_folder) end)
    :ok
  end

  defp hook_on,
    do: Application.put_env(:phoenix_kit_crm, :attachments_parent_folder, {Hook, :parent})

  defp contact_fixture(attrs \\ %{}) do
    {:ok, c} = Contacts.create_contact(Map.merge(%{"name" => "Ada Lovelace"}, attrs))
    c
  end

  defp company_fixture(attrs \\ %{}) do
    {:ok, c} = Companies.create_company(Map.merge(%{"name" => "Acme"}, attrs))
    c
  end

  defp interaction_fixture(contact, attrs \\ %{}) do
    {:ok, i} =
      Interactions.create_interaction(
        Map.merge(
          %{
            "contact_uuid" => contact.uuid,
            "interaction_type" => "note",
            "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    i
  end

  # `phoenix_kit_files.user_uuid` carries an FK constraint, so a raw file
  # insert (bypassing the upload pipeline) needs a real user row.
  defp file_owner_uuid do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "reorg-test-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    user.uuid
  end

  defp create_file(folder_uuid, attrs \\ %{}) do
    base = %{
      original_file_name: "file.pdf",
      file_name: "file-#{System.unique_integer([:positive])}.pdf",
      mime_type: "application/pdf",
      file_type: "document",
      ext: "pdf",
      file_checksum: "checksum-#{System.unique_integer([:positive])}",
      user_file_checksum: "user-checksum-#{System.unique_integer([:positive])}",
      size: 10,
      status: "active",
      folder_uuid: folder_uuid,
      user_uuid: file_owner_uuid()
    }

    {:ok, file} =
      %PhoenixKit.Modules.Storage.File{}
      |> Ecto.Changeset.change(Map.merge(base, attrs))
      |> Repo.insert()

    file
  end

  test "no hook configured, legacy folder already at root → nothing planned" do
    contact = contact_fixture()
    {:ok, _folder} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :contact and &1.label == contact.name))
  end

  test "no hook configured, no folder at all → nothing planned (module creates lazily)" do
    contact = contact_fixture()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :contact and &1.label == contact.name))
  end

  test "hook configured, legacy folder at root → one move action, after_move always nil" do
    contact = contact_fixture(%{"name" => "Käepide"})
    {:ok, target} = Storage.create_folder(%{name: "Contacts"})
    {:ok, folder} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :contact))

    assert action.source == "crm"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == "crm-contact-#{contact.uuid}"
    assert action.on_conflict == :suffix
    assert action.counts == {0, 0}
    assert action.label == contact.name
    assert is_nil(action.after_move)
  end

  test "counts include a trashed file — the engine re-measures the same way at apply time" do
    contact = contact_fixture()
    {:ok, target} = Storage.create_folder(%{name: "Contacts"})
    {:ok, folder} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})
    create_file(folder.uuid, %{status: "trashed"})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :contact))

    assert action.counts == {1, 0}
  end

  test "folder already at the hook-resolved parent/name → nothing planned (no pointer to back-fill)" do
    contact = contact_fixture()
    {:ok, target} = Storage.create_folder(%{name: "Contacts"})

    {:ok, _folder} =
      Storage.create_folder(%{name: "crm-contact-#{contact.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :contact and &1.label == contact.name))
  end

  test "trashed folder at the resolved parent is ignored in favor of a live folder at root" do
    contact = contact_fixture()
    {:ok, target} = Storage.create_folder(%{name: "Contacts"})

    # Highest-priority location by name+parent match — but trashed, so must
    # never be selectable as the current folder.
    {:ok, trashed_at_target} =
      Storage.create_folder(%{name: "crm-contact-#{contact.uuid}", parent_uuid: target.uuid})

    {:ok, _trashed} = Storage.trash_folder(trashed_at_target)

    {:ok, live_root} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :contact and &1.label == contact.name))

    refute is_nil(action)
    assert action.folder.uuid == live_root.uuid
    assert action.parent_uuid == target.uuid
  end

  test "trashed-only folder (no live alternative) → nothing planned" do
    contact = contact_fixture()
    {:ok, folder} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})
    {:ok, _trashed} = Storage.trash_folder(folder)

    {:ok, target} = Storage.create_folder(%{name: "Contacts"})
    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :contact and &1.label == contact.name))
  end

  test "companies and interactions get actions too" do
    contact = contact_fixture()
    company = company_fixture(%{"name" => "Umbrella Corp"})
    interaction = interaction_fixture(contact)

    {:ok, target} = Storage.create_folder(%{name: "Media"})
    {:ok, _} = Storage.create_folder(%{name: "crm-company-#{company.uuid}"})
    {:ok, _} = Storage.create_folder(%{name: "crm-interaction-#{interaction.uuid}"})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])

    assert Enum.any?(actions, &(&1.kind == :company and &1.label == company.name))
    assert Enum.any?(actions, &(&1.kind == :interaction and &1.folder.name =~ interaction.uuid))
  end

  describe "orphan folders" do
    test "legacy folder with no matching contact record → orphan report with counts" do
      {:ok, folder} = Storage.create_folder(%{name: "crm-contact-#{Ecto.UUID.generate()}"})
      create_file(folder.uuid)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "crm"
      assert action.op == :report
      assert action.counts == {1, 0}
      assert action.reason =~ "missing"
      assert action.reason =~ "1 file"
    end

    test "legacy folder of a trashed company → report names the record's status" do
      company = company_fixture()
      {:ok, folder} = Storage.create_folder(%{name: "crm-company-#{company.uuid}"})
      {:ok, _} = Companies.trash_company(company)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "trashed"
    end

    test "legacy folder with no matching interaction record → orphan report" do
      {:ok, folder} = Storage.create_folder(%{name: "crm-interaction-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.reason =~ "missing"
    end

    test "legacy folder of a live interaction → not reported as orphan" do
      contact = contact_fixture()
      interaction = interaction_fixture(contact)
      {:ok, folder} = Storage.create_folder(%{name: "crm-interaction-#{interaction.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "legacy folder of a live contact → not reported as orphan" do
      contact = contact_fixture()
      {:ok, folder} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end
end
