defmodule PhoenixKitCRM.InteractionsTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Contacts, Interactions}
  alias PhoenixKitCRM.Schemas.Interaction

  defp contact_fixture(name \\ "Subject") do
    {:ok, c} = Contacts.create_contact(%{"name" => name})
    c
  end

  defp interaction_attrs(contact, attrs \\ %{}) do
    Map.merge(
      %{
        "contact_uuid" => contact.uuid,
        "interaction_type" => "note",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      },
      attrs
    )
  end

  describe "create_interaction/3" do
    test "creates an interaction anchored to its subject contact" do
      c = contact_fixture()

      assert {:ok, %Interaction{} = i} =
               Interactions.create_interaction(interaction_attrs(c, %{"subject" => "Called"}))

      assert i.subject == "Called"
      assert i.contact_uuid == c.uuid
    end

    test "requires a subject contact_uuid (type + occurred_at default in the schema)" do
      assert {:error, cs} = Interactions.create_interaction(%{})
      assert cs.errors[:contact_uuid]
    end

    test "rejects an invalid interaction_type" do
      c = contact_fixture()

      assert {:error, cs} =
               Interactions.create_interaction(
                 interaction_attrs(c, %{"interaction_type" => "bogus"})
               )

      assert cs.errors[:interaction_type]
    end

    test "stores a resolvable party with a frozen profile snapshot" do
      c = contact_fixture()
      party = contact_fixture("Party Person")

      {:ok, i} =
        Interactions.create_interaction(interaction_attrs(c), [
          %{raw_name: "Party Person", contact_uuid: party.uuid}
        ])

      assert [p] = Interactions.get_interaction(i.uuid).parties
      assert p.raw_name == "Party Person"
      assert p.contact_uuid == party.uuid
      assert p.party_snapshot["source"] == "crm_contact"
      assert p.party_snapshot["name"] == "Party Person"
    end

    test "blank parties are dropped" do
      c = contact_fixture()
      {:ok, i} = Interactions.create_interaction(interaction_attrs(c), [%{raw_name: "  "}])
      assert Interactions.get_interaction(i.uuid).parties == []
    end
  end

  describe "list_involving/1" do
    test "returns interactions where the contact is the subject OR a party" do
      subject = contact_fixture("Subj")
      other = contact_fixture("Other")
      {:ok, own} = Interactions.create_interaction(interaction_attrs(subject))

      {:ok, as_party} =
        Interactions.create_interaction(interaction_attrs(other), [
          %{raw_name: "Subj", contact_uuid: subject.uuid}
        ])

      uuids = subject.uuid |> Interactions.list_involving() |> Enum.map(& &1.uuid)
      assert own.uuid in uuids
      assert as_party.uuid in uuids
    end

    test "returns [] for a malformed uuid" do
      assert Interactions.list_involving("not-a-uuid") == []
    end
  end

  describe "list_for_contacts/1 + interaction_uuids_for_contact/1" do
    test "list_for_contacts returns interactions for the given subjects; [] for empty" do
      a = contact_fixture("A")
      {:ok, i} = Interactions.create_interaction(interaction_attrs(a))

      uuids = [a.uuid] |> Interactions.list_for_contacts() |> Enum.map(& &1.uuid)
      assert i.uuid in uuids
      assert Interactions.list_for_contacts([]) == []
    end

    test "interaction_uuids_for_contact returns the subject's interaction uuids" do
      c = contact_fixture()
      {:ok, i} = Interactions.create_interaction(interaction_attrs(c))
      assert i.uuid in Interactions.interaction_uuids_for_contact(c.uuid)
    end
  end

  describe "update_interaction/4" do
    test "nil party_inputs (the default) keeps the existing parties" do
      c = contact_fixture()
      party = contact_fixture("Party")

      {:ok, i} =
        Interactions.create_interaction(interaction_attrs(c), [
          %{raw_name: "Party", contact_uuid: party.uuid}
        ])

      assert {:ok, _} = Interactions.update_interaction(i, %{"subject" => "Edited"})

      reloaded = Interactions.get_interaction(i.uuid)
      assert reloaded.subject == "Edited"
      assert [p] = reloaded.parties
      assert p.contact_uuid == party.uuid
    end

    test "preserves a party's frozen snapshot across an edit (no re-derive)" do
      c = contact_fixture()
      party = contact_fixture("Original Name")

      {:ok, i} =
        Interactions.create_interaction(interaction_attrs(c), [
          %{raw_name: "Original Name", contact_uuid: party.uuid}
        ])

      [p0] = Interactions.get_interaction(i.uuid).parties
      captured_at0 = p0.party_snapshot["captured_at"]

      # The party's profile changes after the interaction was logged...
      {:ok, _} = Contacts.update_contact(party, %{"name" => "New Name"})

      # ...re-saving the interaction with the same party must NOT rewrite the
      # snapshot to the current name / a new timestamp.
      assert {:ok, _} =
               Interactions.update_interaction(i, %{"subject" => "Edited"}, [
                 %{raw_name: "Original Name", contact_uuid: party.uuid}
               ])

      [p1] = Interactions.get_interaction(i.uuid).parties
      assert p1.party_snapshot["name"] == "Original Name"
      assert p1.party_snapshot["captured_at"] == captured_at0
    end

    test "an explicit empty list clears the parties" do
      c = contact_fixture()
      party = contact_fixture("Party")

      {:ok, i} =
        Interactions.create_interaction(interaction_attrs(c), [
          %{raw_name: "Party", contact_uuid: party.uuid}
        ])

      assert {:ok, _} = Interactions.update_interaction(i, %{"subject" => "Cleared"}, [])
      assert Interactions.get_interaction(i.uuid).parties == []
    end
  end

  describe "delete_interaction/2" do
    test "removes the interaction" do
      c = contact_fixture()
      {:ok, i} = Interactions.create_interaction(interaction_attrs(c))
      assert {:ok, _} = Interactions.delete_interaction(i)
      assert Interactions.get_interaction(i.uuid) == nil
    end
  end

  describe "list_recent/1" do
    test "newest occurred_at first across contacts, capped, with the contact preloaded" do
      a = contact_fixture("Anna")
      b = contact_fixture("Bruno")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, oldest} =
        Interactions.create_interaction(
          interaction_attrs(a, %{"occurred_at" => DateTime.add(now, -3, :hour)})
        )

      {:ok, middle} =
        Interactions.create_interaction(
          interaction_attrs(b, %{"occurred_at" => DateTime.add(now, -2, :hour)})
        )

      {:ok, newest} =
        Interactions.create_interaction(
          interaction_attrs(a, %{"occurred_at" => DateTime.add(now, -1, :hour)})
        )

      assert [first, second] = Interactions.list_recent(limit: 2)
      assert first.uuid == newest.uuid
      assert second.uuid == middle.uuid
      assert first.contact.name == "Anna"

      all_uuids = Interactions.list_recent() |> Enum.map(& &1.uuid)
      assert oldest.uuid in all_uuids
    end

    test "excludes interactions whose subject contact is trashed — the rows link to that page" do
      live = contact_fixture("Live Subject")
      gone = contact_fixture("Gone Subject")
      {:ok, kept} = Interactions.create_interaction(interaction_attrs(live))
      {:ok, hidden} = Interactions.create_interaction(interaction_attrs(gone))
      {:ok, _} = Contacts.trash_contact(gone)

      uuids = Interactions.list_recent() |> Enum.map(& &1.uuid)
      assert kept.uuid in uuids
      refute hidden.uuid in uuids
    end
  end
end
