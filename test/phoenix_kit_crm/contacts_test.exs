defmodule PhoenixKitCRM.ContactsTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Schemas.Contact

  defp contact_fixture(attrs \\ %{}) do
    {:ok, contact} = Contacts.create_contact(Map.merge(%{"name" => "Test Contact"}, attrs))
    contact
  end

  # `connect_user/2` wants a real `%User{}`; the link itself is just the
  # controlled changeset, which is all these tests need.
  defp link_user(contact, user_uuid) do
    contact |> Contact.link_user_changeset(user_uuid) |> PhoenixKit.RepoHelper.repo().update()
  end

  describe "create_contact/1" do
    test "creates an active contact from a name" do
      assert {:ok, %Contact{} = c} = Contacts.create_contact(%{"name" => "Ada Lovelace"})
      assert c.name == "Ada Lovelace"
      assert c.status == "active"
    end

    test "requires a name" do
      assert {:error, cs} = Contacts.create_contact(%{"name" => ""})
      assert cs.errors[:name]
    end

    test "rejects an invalid status" do
      assert {:error, cs} = Contacts.create_contact(%{"name" => "X", "status" => "bogus"})
      assert cs.errors[:status]
    end
  end

  describe "get_contact/1" do
    test "returns the contact by uuid" do
      c = contact_fixture()
      assert Contacts.get_contact(c.uuid).uuid == c.uuid
    end

    test "returns nil for an unknown or malformed uuid" do
      assert Contacts.get_contact(Ecto.UUID.generate()) == nil
      assert Contacts.get_contact("not-a-uuid") == nil
    end
  end

  describe "update_contact/2" do
    test "updates editable fields" do
      c = contact_fixture()
      assert {:ok, updated} = Contacts.update_contact(c, %{"name" => "Renamed"})
      assert updated.name == "Renamed"
    end
  end

  describe "trash_contact/1 + restore_contact/1" do
    test "trash sets the sentinel status and stashes the prior one" do
      assert {:ok, trashed} = Contacts.trash_contact(contact_fixture())
      assert trashed.status == "trashed"
      assert trashed.metadata["trashed_from_status"] == "active"
    end

    test "trashing an already-trashed contact errors" do
      {:ok, trashed} = Contacts.trash_contact(contact_fixture())
      assert {:error, :already_trashed} = Contacts.trash_contact(trashed)
    end

    test "restore reverses the trash and clears the stash" do
      {:ok, trashed} = Contacts.trash_contact(contact_fixture())
      assert {:ok, restored} = Contacts.restore_contact(trashed)
      assert restored.status == "active"
      refute Map.has_key?(restored.metadata, "trashed_from_status")
    end

    test "restoring a non-trashed contact errors" do
      assert {:error, :not_trashed} = Contacts.restore_contact(contact_fixture())
    end
  end

  describe "list_contacts/1 + count_contacts/1" do
    test "active list excludes trashed; trashed filter is the inverse" do
      active = contact_fixture(%{"name" => "Active One"})
      {:ok, trashed} = Contacts.trash_contact(contact_fixture(%{"name" => "Trashed One"}))

      active_uuids = Contacts.list_contacts() |> Enum.map(& &1.uuid)
      assert active.uuid in active_uuids
      refute trashed.uuid in active_uuids

      trashed_uuids = Contacts.list_contacts(status: "trashed") |> Enum.map(& &1.uuid)
      assert trashed.uuid in trashed_uuids
      refute active.uuid in trashed_uuids
    end

    test "count_contacts honors the status filter" do
      contact_fixture()
      {:ok, _} = Contacts.trash_contact(contact_fixture())
      assert Contacts.count_contacts(status: "trashed") == 1
    end

    test "limit/offset page through results in name order; absent means unpaginated" do
      a = contact_fixture(%{"name" => "Alice"})
      b = contact_fixture(%{"name" => "Bob"})
      c = contact_fixture(%{"name" => "Carol"})

      assert Contacts.list_contacts() |> Enum.map(& &1.uuid) == [a.uuid, b.uuid, c.uuid]

      page1 = Contacts.list_contacts(limit: 2, offset: 0) |> Enum.map(& &1.uuid)
      page2 = Contacts.list_contacts(limit: 2, offset: 2) |> Enum.map(& &1.uuid)
      assert page1 == [a.uuid, b.uuid]
      assert page2 == [c.uuid]
    end

    test "search matches by name or email, case-insensitively; combines with limit/offset" do
      alice = contact_fixture(%{"name" => "Alice Wonder", "email" => "alice@example.com"})
      bob = contact_fixture(%{"name" => "Bob Builder", "email" => "wonder@bob.example"})
      contact_fixture(%{"name" => "Carol Danvers", "email" => "carol@example.com"})

      by_name = Contacts.list_contacts(search: "wonder") |> Enum.map(& &1.uuid) |> Enum.sort()
      assert by_name == Enum.sort([alice.uuid, bob.uuid])

      assert Contacts.count_contacts(search: "wonder") == 2

      paged = Contacts.list_contacts(search: "wonder", limit: 1, offset: 0)
      assert length(paged) == 1
    end

    test "escapes LIKE wildcards so % and _ match literally, not everything" do
      pct = contact_fixture(%{"name" => "50% Off Sam"})
      underscore = contact_fixture(%{"name" => "under_score"})
      plain = contact_fixture(%{"name" => "Plain Sam"})

      pct_uuids = Contacts.list_contacts(search: "%") |> Enum.map(& &1.uuid)
      assert pct.uuid in pct_uuids
      refute plain.uuid in pct_uuids
      refute underscore.uuid in pct_uuids

      underscore_uuids = Contacts.list_contacts(search: "_") |> Enum.map(& &1.uuid)
      assert underscore.uuid in underscore_uuids
      refute plain.uuid in underscore_uuids
      refute pct.uuid in underscore_uuids
    end
  end

  describe "list_by_uuids/1" do
    test "returns the contacts for the given uuids; [] for empty input" do
      a = contact_fixture(%{"name" => "A"})
      b = contact_fixture(%{"name" => "B"})
      uuids = [a.uuid, b.uuid] |> Contacts.list_by_uuids() |> Enum.map(& &1.uuid)
      assert a.uuid in uuids and b.uuid in uuids
      assert Contacts.list_by_uuids([]) == []
    end

    test "drops malformed uuids instead of raising" do
      a = contact_fixture(%{"name" => "Valid"})
      assert ["not-a-uuid", a.uuid] |> Contacts.list_by_uuids() |> Enum.map(& &1.uuid) == [a.uuid]
      assert Contacts.list_by_uuids(["also-bad"]) == []
    end
  end

  describe "get_by_user_uuid/1" do
    test "returns nil for nil and for a malformed uuid (no cast error)" do
      assert Contacts.get_by_user_uuid(nil) == nil
      assert Contacts.get_by_user_uuid("not-a-uuid") == nil
    end
  end

  describe "map_by_user_uuids/1" do
    test "keys linked contacts by user_uuid; unlinked users are simply absent" do
      linked_user_uuid = Ecto.UUID.generate()
      unlinked_user_uuid = Ecto.UUID.generate()
      contact = contact_fixture(%{"name" => "Linked"})
      {:ok, contact} = link_user(contact, linked_user_uuid)

      map = Contacts.map_by_user_uuids([linked_user_uuid, unlinked_user_uuid])

      assert map[linked_user_uuid].uuid == contact.uuid
      refute Map.has_key?(map, unlinked_user_uuid)
    end

    test "empty input and malformed uuids yield an empty map instead of raising" do
      assert Contacts.map_by_user_uuids([]) == %{}
      assert Contacts.map_by_user_uuids(["not-a-uuid"]) == %{}
    end
  end

  describe "search_contacts/3" do
    test "matches by name, excluding trashed and the excluded uuids" do
      hit = contact_fixture(%{"name" => "Searchable Sam"})
      excluded = contact_fixture(%{"name" => "Searchable Sue"})
      {:ok, trashed} = Contacts.trash_contact(contact_fixture(%{"name" => "Searchable Trash"}))

      uuids = "Searchable" |> Contacts.search_contacts(8, [excluded.uuid]) |> Enum.map(& &1.uuid)
      assert hit.uuid in uuids
      refute excluded.uuid in uuids
      refute trashed.uuid in uuids
    end

    test "blank query returns no results" do
      contact_fixture(%{"name" => "Whoever"})
      assert Contacts.search_contacts("   ") == []
    end

    test "escapes LIKE wildcards so % matches literally, not everything" do
      pct = contact_fixture(%{"name" => "50% Off Sam"})
      plain = contact_fixture(%{"name" => "Plain Sam"})

      # Unescaped, "%" would be a wildcard matching every contact.
      uuids = "%" |> Contacts.search_contacts() |> Enum.map(& &1.uuid)
      assert pct.uuid in uuids
      refute plain.uuid in uuids
    end

    test "tolerates a null byte in the query (no Postgres crash)" do
      hit = contact_fixture(%{"name" => "Nullsafe Sam"})
      uuids = "Null\x00safe" |> Contacts.search_contacts() |> Enum.map(& &1.uuid)
      assert hit.uuid in uuids
    end
  end

  describe "list_duplicate_email_groups/0 and list_by_email/1" do
    test "groups contacts sharing an email, case-insensitively, 2+ per group" do
      email = "dup-#{System.unique_integer([:positive])}@example.com"
      c1 = contact_fixture(%{"name" => "First", "email" => email})
      c2 = contact_fixture(%{"name" => "Second", "email" => String.upcase(email)})
      # a lone email is not a "duplicate"
      _unique = contact_fixture(%{"name" => "Alone", "email" => "alone@example.com"})

      groups = Contacts.list_duplicate_email_groups()
      assert group = Enum.find(groups, &(String.downcase(&1.email) == email))
      assert group.count == 2

      drilldown = Contacts.list_by_email(group.email)
      assert Enum.sort(Enum.map(drilldown, & &1.uuid)) == Enum.sort([c1.uuid, c2.uuid])
    end

    test "nil/blank emails are never counted as duplicates" do
      contact_fixture(%{"name" => "No Email 1", "email" => nil})
      contact_fixture(%{"name" => "No Email 2", "email" => nil})

      refute Enum.any?(Contacts.list_duplicate_email_groups(), &is_nil(&1.email))
    end

    test "trashed contacts are excluded from duplicate detection" do
      email = "trashed-dup-#{System.unique_integer([:positive])}@example.com"
      c1 = contact_fixture(%{"name" => "Active", "email" => email})
      c2 = contact_fixture(%{"name" => "Will Trash", "email" => email})
      {:ok, _} = Contacts.trash_contact(c2)

      refute Enum.any?(Contacts.list_duplicate_email_groups(), &(&1.email == email))
      assert Enum.map(Contacts.list_by_email(email), & &1.uuid) == [c1.uuid]
    end
  end
end
