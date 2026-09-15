defmodule PhoenixKitCRM.MediaReorganizerTest do
  use PhoenixKitCRM.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Contacts, Interactions, MediaReorganizer}

  defmodule Hook do
    def parent(kind, _actor, subject) when kind in [:contact, :company, :interaction] do
      Process.put(:hook_calls, [{kind, subject} | Process.get(:hook_calls, [])])
      {:ok, Process.get(:target_folder)}
    end

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
    assert action.on_conflict == :report
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

    company_action = Enum.find(actions, &(&1.kind == :company and &1.label == company.name))

    interaction_action =
      Enum.find(actions, &(&1.kind == :interaction and &1.folder.name =~ interaction.uuid))

    refute is_nil(company_action)
    assert company_action.op == :move
    assert company_action.parent_uuid == target.uuid
    assert company_action.on_conflict == :report

    refute is_nil(interaction_action)
    assert interaction_action.op == :move
    assert interaction_action.parent_uuid == target.uuid
    assert interaction_action.on_conflict == :report
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

    test "legacy folder of a trashed company → report names the record's status, never a move" do
      company = company_fixture()
      {:ok, target} = Storage.create_folder(%{name: "Companies"})
      {:ok, folder} = Storage.create_folder(%{name: "crm-company-#{company.uuid}"})
      {:ok, _} = Companies.trash_company(company)

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "trashed"
      refute Enum.any?(actions, &(&1.op == :move and &1.kind == :company))
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

  describe "no hook configured (D1)" do
    test "a contact with a legacy folder at root → plan is entirely empty" do
      contact = contact_fixture()
      {:ok, _folder} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})

      assert MediaReorganizer.plan(nil, []) == []
    end

    test "a contact with a legacy folder NOT at root → plan is entirely empty (untouched)" do
      contact = contact_fixture()
      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere"})

      {:ok, _folder} =
        Storage.create_folder(%{
          name: "crm-contact-#{contact.uuid}",
          parent_uuid: elsewhere.uuid
        })

      assert MediaReorganizer.plan(nil, []) == []
    end
  end

  describe "candidate detection (X12)" do
    test "the parent hook is called exactly once, only for records that already have a folder" do
      with_folder = contact_fixture(%{"name" => "Has Folder"})
      without_folder = contact_fixture(%{"name" => "No Folder"})
      {:ok, target} = Storage.create_folder(%{name: "Contacts"})
      {:ok, _folder} = Storage.create_folder(%{name: "crm-contact-#{with_folder.uuid}"})

      Process.put(:target_folder, target.uuid)
      Process.put(:hook_calls, [])
      hook_on()

      MediaReorganizer.plan(nil, [])

      per_record_calls =
        Process.get(:hook_calls) |> Enum.reject(fn {_kind, subject} -> is_nil(subject) end)

      assert Enum.count(per_record_calls, &(&1 == {:contact, with_folder.uuid})) == 1
      refute {:contact, without_folder.uuid} in per_record_calls
    end
  end

  describe "relocated folders (X9)" do
    test "a legacy folder live only outside root and the resolved parent → reported, never moved" do
      contact = contact_fixture(%{"name" => "Moved Away"})
      {:ok, target} = Storage.create_folder(%{name: "Contacts"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere Else"})

      {:ok, folder} =
        Storage.create_folder(%{
          name: "crm-contact-#{contact.uuid}",
          parent_uuid: elsewhere.uuid
        })

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move and &1.label == contact.name))

      action = Enum.find(actions, &(&1.kind == :relocated and &1.label == contact.name))
      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ folder.uuid
    end
  end

  describe "ambiguous duplicates at root and under the resolved parent (X11)" do
    test "live in both places → one duplicate report, no move" do
      contact = contact_fixture(%{"name" => "Twinned"})
      {:ok, target} = Storage.create_folder(%{name: "Contacts"})
      {:ok, at_root} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})

      {:ok, under_parent} =
        Storage.create_folder(%{
          name: "crm-contact-#{contact.uuid}",
          parent_uuid: target.uuid
        })

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move and &1.label == contact.name))

      action = Enum.find(actions, &(&1.kind == :duplicate and &1.label == contact.name))
      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ at_root.uuid
      assert action.reason =~ under_parent.uuid
    end
  end

  describe "interactions anchored to a trashed contact/company (D8)" do
    test "skipped by move-planning, its folder reported as an orphan naming the trashed contact" do
      contact = contact_fixture()
      interaction = interaction_fixture(contact)
      {:ok, folder} = Storage.create_folder(%{name: "crm-interaction-#{interaction.uuid}"})
      {:ok, target} = Storage.create_folder(%{name: "Media"})

      {:ok, _} = Contacts.trash_contact(contact)

      Process.put(:target_folder, target.uuid)
      Process.put(:hook_calls, [])
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.op == :move and &1.kind == :interaction))

      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "contact"
      assert action.reason =~ "trashed"

      # D8: the interaction itself never triggers the parent hook.
      per_record_calls =
        Process.get(:hook_calls) |> Enum.reject(fn {_kind, subject} -> is_nil(subject) end)

      refute {:interaction, interaction.uuid} in per_record_calls
    end

    test "company anchor trashed → same orphan treatment" do
      company = company_fixture()

      {:ok, interaction} =
        Interactions.create_interaction(%{
          "company_uuid" => company.uuid,
          "interaction_type" => "note",
          "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, folder} = Storage.create_folder(%{name: "crm-interaction-#{interaction.uuid}"})
      {:ok, target} = Storage.create_folder(%{name: "Media"})

      {:ok, _} = Companies.trash_company(company)

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
      refute is_nil(action)
      assert action.reason =~ "company"
      assert action.reason =~ "trashed"
    end
  end

  describe "orphans under a resolved parent with zero live records of that kind (X13)" do
    test "a legacy folder under the kind's default parent is still found when every record is trashed" do
      company = company_fixture()
      {:ok, target} = Storage.create_folder(%{name: "Companies"})

      {:ok, folder} =
        Storage.create_folder(%{name: "crm-company-#{company.uuid}", parent_uuid: target.uuid})

      {:ok, _} = Companies.trash_company(company)

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
      refute is_nil(action)
      assert action.reason =~ "trashed"
    end
  end

  describe "Images subfolder" do
    test "moving the root folder does not touch the nested Images subfolder" do
      contact = contact_fixture()
      {:ok, target} = Storage.create_folder(%{name: "Contacts"})
      {:ok, root} = Storage.create_folder(%{name: "crm-contact-#{contact.uuid}"})
      {:ok, images} = Storage.create_folder(%{name: "Images", parent_uuid: root.uuid})

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      assert [action] = Enum.filter(actions, &(&1.label == contact.name))
      assert action.op == :move
      assert action.folder.uuid == root.uuid
      refute Enum.any?(actions, &(Map.get(&1, :folder) && &1.folder.uuid == images.uuid))
    end
  end
end
