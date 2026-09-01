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

  describe "company-anchored interactions (V05)" do
    defp company_fixture(name \\ "Acme Anchor Co") do
      {:ok, company} = PhoenixKitCRM.Companies.create_company(%{"name" => name})
      company
    end

    defp company_attrs(company, attrs \\ %{}) do
      Map.merge(
        %{
          "company_uuid" => company.uuid,
          "interaction_type" => "call",
          "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    end

    test "exactly one anchor: neither and both are changeset errors, not DB 500s" do
      company = company_fixture()
      contact = contact_fixture()

      assert {:error, cs} =
               Interactions.create_interaction(%{
                 "interaction_type" => "note",
                 "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
               })

      assert cs.errors[:contact_uuid]

      assert {:error, cs} =
               Interactions.create_interaction(
                 company_attrs(company, %{"contact_uuid" => contact.uuid})
               )

      assert cs.errors[:company_uuid]
    end

    test "list_for_company scopes: :company, :members, and :all as one merged window" do
      company = company_fixture()
      member = contact_fixture("Member Mia")
      {:ok, _} = Contacts.set_primary_company(member, company.uuid, "Eng", nil)
      outsider = contact_fixture("Outsider Otto")

      {:ok, own} = Interactions.create_interaction(company_attrs(company))
      {:ok, member_own} = Interactions.create_interaction(interaction_attrs(member))
      {:ok, unrelated} = Interactions.create_interaction(interaction_attrs(outsider))

      company_uuids =
        Interactions.list_for_company(company.uuid, scope: :company) |> Enum.map(& &1.uuid)

      assert company_uuids == [own.uuid]

      member_uuids =
        Interactions.list_for_company(company.uuid, scope: :members) |> Enum.map(& &1.uuid)

      assert member_own.uuid in member_uuids
      refute own.uuid in member_uuids

      all_uuids = Interactions.list_for_company(company.uuid) |> Enum.map(& &1.uuid)
      assert own.uuid in all_uuids
      assert member_own.uuid in all_uuids
      refute unrelated.uuid in all_uuids

      # :limit applies to the MERGED window, newest first — the two rows get
      # DISTINCT times so a per-arm limit (the bug this pins against) could
      # not sneak the older row through.
      {:ok, _} =
        Interactions.update_interaction(own, %{
          "occurred_at" =>
            DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
        })

      {:ok, _} =
        Interactions.update_interaction(member_own, %{
          "occurred_at" =>
            DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        })

      assert [first] = Interactions.list_for_company(company.uuid, limit: 1)
      assert first.uuid == member_own.uuid
    end

    test "a trashed member leaves :members and :all — the roster rule, in the feed" do
      company = company_fixture("Roster Rule Co")
      mia = contact_fixture("Member Mia")
      {:ok, _} = Contacts.set_primary_company(mia, company.uuid, "Eng", nil)
      {:ok, mias_own} = Interactions.create_interaction(interaction_attrs(mia))
      {:ok, _} = Contacts.trash_contact(mia)

      refute mias_own.uuid in (Interactions.list_for_company(company.uuid, scope: :members)
                               |> Enum.map(& &1.uuid))

      refute mias_own.uuid in (Interactions.list_for_company(company.uuid) |> Enum.map(& &1.uuid))
    end

    test "update_changeset still enforces the non-anchor rules" do
      company = company_fixture()
      {:ok, interaction} = Interactions.create_interaction(company_attrs(company))

      assert {:error, cs} =
               Interactions.update_interaction(interaction, %{
                 "interaction_type" => "carrier-pigeon"
               })

      assert cs.errors[:interaction_type]

      assert {:error, cs} =
               Interactions.update_interaction(interaction, %{
                 "subject" => String.duplicate("x", 256)
               })

      assert cs.errors[:subject]
    end

    test "a company-anchored row with a contact party reaches that contact's involving feed, company preloaded" do
      company = company_fixture()
      anna = contact_fixture("Party Anna")

      {:ok, interaction} =
        Interactions.create_interaction(company_attrs(company), [
          %{raw_name: "Party Anna", contact_uuid: anna.uuid}
        ])

      assert [row] = Interactions.list_involving(anna.uuid)
      assert row.uuid == interaction.uuid
      assert row.company.name == "Acme Anchor Co"
    end

    test "involving feed hides company-anchored rows once the company is trashed" do
      company = company_fixture("Doomed Co")
      anna = contact_fixture("Party Anna")

      {:ok, _} =
        Interactions.create_interaction(company_attrs(company), [
          %{raw_name: "Party Anna", contact_uuid: anna.uuid}
        ])

      {:ok, _} = PhoenixKitCRM.Companies.trash_company(company)

      assert Interactions.list_involving(anna.uuid) == []
    end

    test "list_recent includes company-anchored rows and hides trashed-company ones" do
      kept_co = company_fixture("Kept Co")
      doomed_co = company_fixture("Doomed Co")
      {:ok, kept} = Interactions.create_interaction(company_attrs(kept_co))
      {:ok, hidden} = Interactions.create_interaction(company_attrs(doomed_co))
      {:ok, _} = PhoenixKitCRM.Companies.trash_company(doomed_co)

      rows = Interactions.list_recent()
      uuids = Enum.map(rows, & &1.uuid)
      assert kept.uuid in uuids
      refute hidden.uuid in uuids
      assert Enum.find(rows, &(&1.uuid == kept.uuid)).company.name == "Kept Co"
    end

    test "hard-deleting a company cleans up after the cascade: deletion broadcasts reach party feeds" do
      company = company_fixture("Doomed Cascade Co")
      anna = contact_fixture("Party Anna")

      {:ok, interaction} =
        Interactions.create_interaction(company_attrs(company), [
          %{raw_name: "Party Anna", contact_uuid: anna.uuid}
        ])

      :ok =
        PhoenixKitCRM.PubSub.subscribe(PhoenixKitCRM.PubSub.topic_contact_interactions(anna.uuid))

      {:ok, _} = PhoenixKitCRM.Companies.delete_company(company)

      # The DB cascade removed the row; the cleanup path still tells Anna's
      # open feed (and purged the media folder — best-effort, not assertable
      # without storage).
      interaction_uuid = interaction.uuid
      assert_receive {:crm, :interaction_deleted, %{interaction_uuid: ^interaction_uuid}}
      assert Interactions.get_interaction(interaction.uuid) == nil
    end

    test "trashing and restoring a company tells party feeds their rows changed visibility" do
      company = company_fixture("Blinking Co")
      anna = contact_fixture("Party Anna")

      {:ok, _} =
        Interactions.create_interaction(company_attrs(company), [
          %{raw_name: "Party Anna", contact_uuid: anna.uuid}
        ])

      :ok =
        PhoenixKitCRM.PubSub.subscribe(PhoenixKitCRM.PubSub.topic_contact_interactions(anna.uuid))

      {:ok, trashed} = PhoenixKitCRM.Companies.trash_company(company)
      company_uuid = company.uuid
      assert_receive {:crm, :company_visibility_changed, %{company_uuid: ^company_uuid}}

      {:ok, _} = PhoenixKitCRM.Companies.restore_company(trashed)
      assert_receive {:crm, :company_visibility_changed, %{company_uuid: ^company_uuid}}
    end

    test "the anchor is immutable: an update smuggling anchor fields is silently ignored" do
      company = company_fixture()
      other = contact_fixture("Other Contact")
      {:ok, interaction} = Interactions.create_interaction(company_attrs(company))

      {:ok, updated} =
        Interactions.update_interaction(interaction, %{
          "subject" => "Edited",
          "contact_uuid" => other.uuid,
          "company_uuid" => nil
        })

      assert updated.subject == "Edited"
      assert updated.company_uuid == company.uuid
      assert updated.contact_uuid == nil
    end
  end
end
