defmodule PhoenixKitCRM.ContactDeleteCountersTest do
  @moduledoc """
  Hard-deleting a contact cascades its `ListMember` rows at the DB
  level (FK `ON DELETE CASCADE`), bypassing
  `Lists.remove_from_list/2`'s atomic `subscriber_count` decrement —
  that path only fires on a live status flip, not a row disappearing
  out from under it. A contact deleted while still `"subscribed"` on a
  list left that list's `subscriber_count` permanently overcounted,
  since nothing else ever revisits it (a real user hit this: a list
  reading "2" with only one actual member, from a reviewer's fixture
  contact deleted directly).
  """

  # async: false — deliberately, not the suite's default. One test below
  # runs a real `ALTER TABLE ... DROP CONSTRAINT` inside its sandboxed
  # transaction (see its own comment for why the DDL, not a genuine
  # concurrency race, is the right way to reproduce that scenario). DDL
  # takes an ACCESS EXCLUSIVE lock on `phoenix_kit_crm_list_members` for
  # the rest of that transaction — i.e. until the sandbox rolls it back
  # at test end — and several OTHER async: true files (companies_test.exs,
  # lists_test.exs, lists/import_test.exs) read/write that same table
  # concurrently. Confirmed live: `mix test --repeat-until-failure 30`
  # hit `** (Postgrex.Error) ERROR 40P01 (deadlock_detected)` on the very
  # first repetition (seed 763135) — this test's connection waiting on
  # the table-level ACCESS EXCLUSIVE the DDL needs, while blocked by a
  # concurrent connection waiting on a row lock this transaction already
  # held, the textbook two-process cycle. This was the rare "1 failure in
  # 8 full-suite runs" flake. Do not flip this back to async: true, and
  # do not use this as precedent for adding DDL to other async tests —
  # the fix here is isolating the ONE file that genuinely needs DDL, not
  # a blanket policy change.
  use PhoenixKitCRM.DataCase, async: false

  alias PhoenixKitCRM.{Contacts, Lists}
  alias PhoenixKitCRM.Schemas.ListMember

  defp contact_fixture(attrs \\ %{}) do
    {:ok, contact} =
      Contacts.create_contact(
        Map.merge(%{"name" => "Jane Trader", "email" => unique_email()}, attrs)
      )

    contact
  end

  defp list_fixture(attrs \\ %{}) do
    {:ok, list} =
      Lists.create_list(
        Map.merge(%{"name" => "Newsletter", "slug" => "newsletter-#{unique_int()}"}, attrs)
      )

    list
  end

  defp unique_email, do: "contact-#{unique_int()}@example.com"
  defp unique_int, do: System.unique_integer([:positive])

  describe "delete_contact/1" do
    test "decrements subscriber_count only on lists where the contact was actually subscribed" do
      contact = contact_fixture()
      subscribed_list = list_fixture(%{"slug" => "subscribed-#{unique_int()}"})
      removed_list = list_fixture(%{"slug" => "removed-#{unique_int()}"})

      {:ok, _} = Lists.add_contact_to_list(contact, subscribed_list)

      {:ok, _} = Lists.add_contact_to_list(contact, removed_list)
      {:ok, _} = Lists.remove_from_list(contact, removed_list, [])

      assert Lists.get_list!(subscribed_list.uuid).subscriber_count == 1
      assert Lists.get_list!(removed_list.uuid).subscriber_count == 0

      assert {:ok, _} = Contacts.delete_contact(contact)

      assert Lists.get_list!(subscribed_list.uuid).subscriber_count == 0
      assert Lists.get_list!(removed_list.uuid).subscriber_count == 0
    end

    test "the contact and its memberships are actually gone (the FK cascade itself still runs)" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, member} = Lists.add_contact_to_list(contact, list)

      assert {:ok, _} = Contacts.delete_contact(contact)

      assert Repo.get(PhoenixKitCRM.Schemas.Contact, contact.uuid) == nil
      assert Repo.get(ListMember, member.uuid) == nil
    end

    test "a contact with no subscribed memberships at all deletes cleanly, no list touched" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, _} = Lists.add_contact_to_list(contact, list)
      {:ok, _} = Lists.remove_from_list(contact, list, [])

      assert Lists.get_list!(list.uuid).subscriber_count == 0
      assert {:ok, _} = Contacts.delete_contact(contact)
      assert Lists.get_list!(list.uuid).subscriber_count == 0
    end

    test "a contact on multiple subscribed lists decrements every one of them" do
      contact = contact_fixture()
      list_a = list_fixture(%{"slug" => "a-#{unique_int()}"})
      list_b = list_fixture(%{"slug" => "b-#{unique_int()}"})

      {:ok, _} = Lists.add_contact_to_list(contact, list_a)
      {:ok, _} = Lists.add_contact_to_list(contact, list_b)

      assert {:ok, _} = Contacts.delete_contact(contact)

      assert Lists.get_list!(list_a.uuid).subscriber_count == 0
      assert Lists.get_list!(list_b.uuid).subscriber_count == 0
    end

    test "a failed delete rolls back the transaction (rollback hygiene; the pre-delete snapshot here is empty)" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      assert Lists.get_list!(list.uuid).subscriber_count == 1

      # Force repo().delete(contact) to fail deterministically: the row is
      # already gone (bypassing delete_contact/1 to remove it directly, the
      # same shape of gap the FK cascade always leaves — subscriber_count
      # is NOT decremented by this raw delete). The stale `contact` struct
      # then makes delete_contact/1's own repo().delete/1 match zero rows,
      # raising Ecto.StaleEntryError — same rollback trigger
      # repo().transaction/1 uses for any failure, exercised without a
      # flaky concurrency race.
      Repo.delete!(contact)

      assert_raise Ecto.StaleEntryError, fn -> Contacts.delete_contact(contact) end

      # The failed second call must not have left the counter in some new,
      # different-but-still-wrong state.
      assert Lists.get_list!(list.uuid).subscriber_count == 1
    end

    test "recount_list on a list whose row vanished returns :missing instead of raising" do
      {:ok, list} =
        Lists.create_list(%{
          "name" => "Vanishing",
          "slug" => "vanishing-#{System.unique_integer([:positive])}"
        })

      # Simulate the TOCTOU: the struct is loaded, but the row is gone by
      # the time the recount's UPDATE runs — exactly what a concurrent
      # list deletion inside delete_contact's window produces.
      PhoenixKit.RepoHelper.repo().delete!(list)

      assert :missing = Lists.recount_list(list)
    end

    test "a list gone by the time recount_by_uuid checks it doesn't crash the delete (nil branch)" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, _member} = Lists.add_contact_to_list(contact, list)

      # Reproduces "the list vanished before delete_contact/1 recounts it"
      # deterministically, without a flaky concurrency race: temporarily
      # drop the FK (rolled back with the rest of this sandboxed
      # transaction — never touches the real schema) so the ListMember
      # row can outlive the ContactList row it references, then delete
      # the list directly — the membership row itself is untouched, still
      # "subscribed", so delete_contact/1's own snapshot below still
      # finds it and includes this list_uuid. What's gone is the list
      # ROW, so its subsequent recount_by_uuid/1 call hits the `nil ->
      # :ok` branch, not the rescue clause (that one guards a narrower
      # TOCTOU gap between recount_by_uuid's own get/2 and
      # Lists.recount_list/1's update_all, not reproducible without a
      # genuine two-connection race).
      Repo.query!("""
      ALTER TABLE phoenix_kit_crm_list_members
        DROP CONSTRAINT phoenix_kit_crm_list_members_list_uuid_fkey
      """)

      Repo.delete!(list)

      assert {:ok, _} = Contacts.delete_contact(contact)
      assert Repo.get(PhoenixKitCRM.Schemas.Contact, contact.uuid) == nil
    end
  end

  describe "trash_contact/1 (soft delete)" do
    test "does not cascade memberships and does not touch subscriber_count" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, member} = Lists.add_contact_to_list(contact, list)

      assert Lists.get_list!(list.uuid).subscriber_count == 1

      assert {:ok, trashed} = Contacts.trash_contact(contact)
      assert trashed.status == "trashed"

      # The membership row is untouched — trashing only flips the contact's
      # own status, it never deletes anything.
      assert Repo.get(ListMember, member.uuid).status == "subscribed"
      assert Lists.get_list!(list.uuid).subscriber_count == 1
    end
  end
end
