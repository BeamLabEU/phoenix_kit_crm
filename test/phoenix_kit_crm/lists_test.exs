defmodule PhoenixKitCRM.ListsTest do
  use PhoenixKitCRM.DataCase, async: true

  import PhoenixKitCRM.ActivityLogAssertions

  alias PhoenixKitCRM.{Contacts, Lists, PubSub}
  alias PhoenixKitCRM.Schemas.{Contact, ContactList, ListMember}

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

  # ── Lists CRUD ──────────────────────────────────────────────────────

  describe "create_list/2" do
    test "creates a list with the given attrs" do
      assert {:ok, %ContactList{} = list} =
               Lists.create_list(%{"name" => "Customers", "slug" => "customers"})

      assert list.name == "Customers"
      assert list.slug == "customers"
      assert list.status == "active"
      refute list.subscribable
      assert list.subscriber_count == 0
    end

    test "auto-generates a slug from the name when omitted" do
      assert {:ok, list} = Lists.create_list(%{"name" => "VIP Customers"})
      assert list.slug == "vip-customers"
    end

    test "requires name and slug" do
      assert {:error, changeset} = Lists.create_list(%{})
      assert changeset.errors[:name]
    end

    test "rejects a duplicate slug" do
      list_fixture(%{"slug" => "dup-slug"})
      assert {:error, changeset} = Lists.create_list(%{"name" => "Other", "slug" => "dup-slug"})
      assert changeset.errors[:slug]
    end

    test "logs the creation with the given actor_uuid" do
      actor_uuid = Ecto.UUID.generate()
      assert {:ok, list} = Lists.create_list(%{"name" => "Logged"}, actor_uuid: actor_uuid)

      assert_activity_logged("crm.list_created",
        resource_uuid: list.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "accepts a blank locale (not set), and a well-formed one" do
      assert {:ok, list} = Lists.create_list(%{"name" => "No Locale"})
      assert list.locale == nil

      assert {:ok, list} = Lists.create_list(%{"name" => "With Locale", "locale" => "en-US"})
      assert list.locale == "en-US"
    end

    test "rejects a malformed locale" do
      assert {:error, changeset} =
               Lists.create_list(%{"name" => "Bad Locale", "locale" => "not a locale"})

      assert changeset.errors[:locale]
    end
  end

  describe "update_list/3" do
    test "updates list attrs" do
      list = list_fixture()
      assert {:ok, updated} = Lists.update_list(list, %{"name" => "Renamed"})
      assert updated.name == "Renamed"
    end
  end

  describe "archive_list/2 and unarchive_list/2" do
    test "archive flips status without deleting the row" do
      list = list_fixture()
      assert {:ok, archived} = Lists.archive_list(list)
      assert archived.status == "archived"
      assert Lists.get_list(list.uuid)
    end

    test "archive is idempotent" do
      list = list_fixture()
      {:ok, archived} = Lists.archive_list(list)
      assert {:ok, ^archived} = Lists.archive_list(archived)
    end

    test "unarchive flips status back to active" do
      list = list_fixture()
      {:ok, archived} = Lists.archive_list(list)
      assert {:ok, unarchived} = Lists.unarchive_list(archived)
      assert unarchived.status == "active"
    end

    test "unarchive is idempotent" do
      list = list_fixture()
      assert {:ok, ^list} = Lists.unarchive_list(list)
    end
  end

  describe "list_lists/1" do
    test "filters by status and subscribable" do
      active = list_fixture(%{"name" => "Active One"})
      {:ok, archived} = list_fixture(%{"name" => "Archived One"}) |> Lists.archive_list()
      subscribable = list_fixture(%{"name" => "Subscribable", "subscribable" => true})

      assert Lists.list_lists(status: "active") |> Enum.map(& &1.uuid) |> Enum.sort() ==
               Enum.sort([active.uuid, subscribable.uuid])

      assert Lists.list_lists(status: "archived") |> Enum.map(& &1.uuid) == [archived.uuid]
      assert Lists.list_lists(subscribable: true) |> Enum.map(& &1.uuid) == [subscribable.uuid]
    end
  end

  describe "count_lists/1" do
    test "honors the same filters as list_lists/1" do
      _active = list_fixture(%{"name" => "Active One"})
      {:ok, _archived} = list_fixture(%{"name" => "Archived One"}) |> Lists.archive_list()

      # The Overview count card counts active lists, because the Lists page it
      # links to opens on the Active tab — an unfiltered total would promise
      # rows the next screen doesn't show.
      assert Lists.count_lists(status: "active") == 1
      assert Lists.count_lists(status: "archived") == 1
      assert Lists.count_lists() == 2
    end
  end

  describe "get_list/1, get_list!/1, get_list_by_slug/1" do
    test "get_list/1 returns nil for a bad id" do
      refute Lists.get_list(Ecto.UUID.generate())
      refute Lists.get_list("not-a-uuid")
    end

    test "get_list!/1 raises for a missing id" do
      assert_raise Ecto.NoResultsError, fn -> Lists.get_list!(Ecto.UUID.generate()) end
    end

    test "get_list_by_slug/1 finds by slug, nil otherwise" do
      list = list_fixture(%{"slug" => "find-me"})
      assert Lists.get_list_by_slug("find-me").uuid == list.uuid
      refute Lists.get_list_by_slug("missing")
      refute Lists.get_list_by_slug(nil)
    end
  end

  # ── Membership ──────────────────────────────────────────────────────

  describe "add_contact_to_list/3" do
    test "snapshots the contact's email and sets subscribed_at" do
      contact = contact_fixture(%{"email" => "snap@example.com"})
      list = list_fixture()

      assert {:ok, %ListMember{} = member} = Lists.add_contact_to_list(contact, list)
      assert member.email == "snap@example.com"
      assert member.status == "subscribed"
      assert member.source == "manual"
      assert member.subscribed_at
    end

    test "honors the :source option" do
      contact = contact_fixture()
      list = list_fixture()

      assert {:ok, member} = Lists.add_contact_to_list(contact, list, source: "import")
      assert member.source == "import"
    end

    test "allows a nil-email contact, and several of them in the same list" do
      list = list_fixture()
      c1 = contact_fixture(%{"email" => nil})
      c2 = contact_fixture(%{"email" => nil})

      assert {:ok, m1} = Lists.add_contact_to_list(c1, list)
      assert {:ok, m2} = Lists.add_contact_to_list(c2, list)
      assert m1.email == nil
      assert m2.email == nil
    end

    test "returns {:error, :already_member} when the same contact is added twice" do
      contact = contact_fixture()
      list = list_fixture()

      assert {:ok, _} = Lists.add_contact_to_list(contact, list)
      assert {:error, :already_member} = Lists.add_contact_to_list(contact, list)
    end

    test "returns {:error, :email_already_in_list} when a different contact shares the email in the same list" do
      list = list_fixture()
      email = "shared@example.com"
      c1 = contact_fixture(%{"email" => email})
      c2 = contact_fixture(%{"email" => email})

      assert {:ok, _} = Lists.add_contact_to_list(c1, list)
      assert {:error, :email_already_in_list} = Lists.add_contact_to_list(c2, list)
    end

    test "a removed member still holds its email slot (re-add under a new contact still collides)" do
      list = list_fixture()
      email = "held@example.com"
      c1 = contact_fixture(%{"email" => email})
      c2 = contact_fixture(%{"email" => email})

      {:ok, member} = Lists.add_contact_to_list(c1, list)
      {:ok, _} = Lists.remove_from_list(member)

      assert {:error, :email_already_in_list} = Lists.add_contact_to_list(c2, list)
    end

    test "logs the mutation with the given actor_uuid" do
      actor_uuid = Ecto.UUID.generate()
      contact = contact_fixture()
      list = list_fixture()

      assert {:ok, member} = Lists.add_contact_to_list(contact, list, actor_uuid: actor_uuid)

      assert_activity_logged("crm.list_member_added",
        resource_uuid: member.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "reactivates a removed member instead of permanently blocking re-add" do
      # idx_crm_list_members_list_contact has no status predicate, so a blind
      # insert here would hit :already_member forever once a contact has ever
      # had any row for this list — this is the regression test for that bug.
      contact = contact_fixture(%{"email" => "reactivate@example.com"})
      list = list_fixture()

      {:ok, member} = Lists.add_contact_to_list(contact, list)
      {:ok, removed} = Lists.remove_from_list(member)
      assert removed.status == "removed"
      assert Lists.get_list!(list.uuid).subscriber_count == 0

      assert {:ok, reactivated} = Lists.add_contact_to_list(contact, list, source: "manual")
      assert reactivated.uuid == member.uuid
      assert reactivated.status == "subscribed"
      assert reactivated.unsubscribed_at == nil
      assert reactivated.subscribed_at
      assert reactivated.email == "reactivate@example.com"
      assert Lists.subscribed?(contact, list)
      assert Lists.get_list!(list.uuid).subscriber_count == 1
    end

    test "reactivation refreshes the email snapshot from the contact's current email" do
      contact = contact_fixture(%{"email" => "old@example.com"})
      list = list_fixture()

      {:ok, member} = Lists.add_contact_to_list(contact, list)
      {:ok, _} = Lists.remove_from_list(member)

      {:ok, updated_contact} = Contacts.update_contact(contact, %{"email" => "new@example.com"})
      assert {:ok, reactivated} = Lists.add_contact_to_list(updated_contact, list)
      assert reactivated.email == "new@example.com"
    end

    test "reactivates a pending member" do
      contact = contact_fixture()
      list = list_fixture()

      pending =
        %ListMember{}
        |> ListMember.changeset(%{
          "list_uuid" => list.uuid,
          "contact_uuid" => contact.uuid,
          "status" => "pending",
          "source" => "form"
        })
        |> Repo.insert!()

      assert {:ok, reactivated} = Lists.add_contact_to_list(contact, list)
      assert reactivated.uuid == pending.uuid
      assert reactivated.status == "subscribed"
    end

    test "reactivating a removed member logs the activity and broadcasts :member_added" do
      contact = contact_fixture()
      list = list_fixture()

      {:ok, member} = Lists.add_contact_to_list(contact, list)
      {:ok, _} = Lists.remove_from_list(member)

      PubSub.subscribe(PubSub.topic_lists())
      actor_uuid = Ecto.UUID.generate()

      assert {:ok, reactivated} =
               Lists.add_contact_to_list(contact, list, actor_uuid: actor_uuid)

      list_uuid = list.uuid
      reactivated_uuid = reactivated.uuid

      # "crm:lists" is a real, global (non-sandboxed) PubSub topic shared by
      # every async test that mutates a list, so a stray broadcast from an
      # unrelated concurrent test (e.g. another test's own "first member
      # added, count=1") can otherwise satisfy an unpinned pattern here —
      # pin list_uuid/member_uuid to the values THIS test just produced
      # instead of capturing whatever arrives first. Generous timeout for
      # scheduler jitter under that same concurrent load.
      assert_receive {:crm, :member_added,
                      %{
                        list_uuid: ^list_uuid,
                        member_uuid: ^reactivated_uuid,
                        subscriber_count: 1
                      }},
                     1000

      assert_activity_logged("crm.list_member_added",
        resource_uuid: reactivated.uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "members_by_email/3" do
    test "returns an empty map for an empty email list, without querying" do
      list = list_fixture()
      assert Lists.members_by_email(list, []) == %{}
    end

    test "looks up members by email, keyed by the downcased email" do
      list = list_fixture()
      contact = contact_fixture(%{"email" => "Mixed.Case@Example.com"})
      {:ok, member} = Lists.add_contact_to_list(contact, list)

      result = Lists.members_by_email(list, ["mixed.case@example.com", "unknown@example.com"])

      assert %{"mixed.case@example.com" => %ListMember{uuid: uuid}} = result
      assert uuid == member.uuid
      refute Map.has_key?(result, "unknown@example.com")
    end

    test "chunk_size splits the query into multiple round trips and merges every result" do
      list = list_fixture()

      members =
        for _ <- 1..5 do
          contact = contact_fixture()
          {:ok, member} = Lists.add_contact_to_list(contact, list)
          member
        end

      emails = Enum.map(members, & &1.email)

      # chunk_size: 2 forces 3 chunked queries (2 + 2 + 1) for 5 emails —
      # proves chunking doesn't drop or duplicate results across the
      # boundary, not just that the default works for a handful of emails.
      result = Lists.members_by_email(list, emails, 2)

      assert map_size(result) == 5

      for member <- members do
        assert %{uuid: uuid} = Map.fetch!(result, String.downcase(member.email))
        assert uuid == member.uuid
      end
    end

    test "a chunk_size larger than the email count still returns every match (single chunk)" do
      list = list_fixture()
      contact = contact_fixture()
      {:ok, member} = Lists.add_contact_to_list(contact, list)

      result = Lists.members_by_email(list, [contact.email], 10_000)

      assert %{uuid: uuid} = Map.fetch!(result, String.downcase(contact.email))
      assert uuid == member.uuid
    end
  end

  describe "subscribed?/2 and remove_from_list/2,3" do
    test "subscribed? flips to false after remove, membership row stays" do
      contact = contact_fixture()
      list = list_fixture()

      refute Lists.subscribed?(contact, list)
      {:ok, member} = Lists.add_contact_to_list(contact, list)
      assert Lists.subscribed?(contact, list)

      assert {:ok, removed} = Lists.remove_from_list(member)
      assert removed.status == "removed"
      assert removed.unsubscribed_at
      refute Lists.subscribed?(contact, list)
    end

    test "remove_from_list/2 is idempotent" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, member} = Lists.add_contact_to_list(contact, list)

      {:ok, removed_once} = Lists.remove_from_list(member)
      assert {:ok, removed_twice} = Lists.remove_from_list(removed_once)
      assert removed_twice.uuid == removed_once.uuid

      # counter must not double-decrement on the idempotent no-op
      assert Lists.get_list!(list.uuid).subscriber_count == 0
    end

    test "remove_from_list/2 called twice with the SAME stale struct does not double-decrement" do
      # Regression for a TOCTOU: the old implementation decided whether to
      # bump_counter(-1) from the passed-in struct's (possibly stale)
      # status, then wrote via a separate `repo().update()` — two calls (or
      # two concurrent processes) racing off the same pre-removal read
      # could each see "subscribed" and each decrement. remove_from_list/2
      # now makes the guard and the write one atomic update_all, so this
      # SAME stale struct (still status: "subscribed", never re-fetched)
      # must only pay the counter once.
      contact = contact_fixture()
      list = list_fixture()
      {:ok, member} = Lists.add_contact_to_list(contact, list)
      assert member.status == "subscribed"

      assert {:ok, _} = Lists.remove_from_list(member)
      assert Lists.get_list!(list.uuid).subscriber_count == 0

      assert {:ok, _} = Lists.remove_from_list(member)
      assert Lists.get_list!(list.uuid).subscriber_count == 0
    end

    test "remove_from_list/3 (contact, list) looks up the membership" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      assert {:ok, removed} = Lists.remove_from_list(contact, list, [])
      assert removed.status == "removed"
    end

    test "remove_from_list/3 returns {:error, :not_member} when there's no membership" do
      contact = contact_fixture()
      list = list_fixture()

      assert {:error, :not_member} = Lists.remove_from_list(contact, list, [])
    end
  end

  describe "list_members/2" do
    test "filters by status and searches by email/contact name" do
      list = list_fixture()
      alice = contact_fixture(%{"name" => "Alice Wonder", "email" => "alice@example.com"})
      bob = contact_fixture(%{"name" => "Bob Builder", "email" => "bob@example.com"})

      {:ok, alice_member} = Lists.add_contact_to_list(alice, list)
      {:ok, bob_member} = Lists.add_contact_to_list(bob, list)
      {:ok, _} = Lists.remove_from_list(bob_member)

      subscribed = Lists.list_members(list, status: "subscribed")
      assert Enum.map(subscribed, & &1.uuid) == [alice_member.uuid]

      by_name = Lists.list_members(list, search: "wonder")
      assert Enum.map(by_name, & &1.uuid) == [alice_member.uuid]

      by_email = Lists.list_members(list, search: "bob@")
      assert Enum.map(by_email, & &1.uuid) == [bob_member.uuid]
    end

    test "escapes LIKE wildcards so % and _ match literally, not everything" do
      list = list_fixture()
      pct = contact_fixture(%{"name" => "50% Off Sam"})
      underscore = contact_fixture(%{"name" => "under_score"})
      plain = contact_fixture(%{"name" => "Plain Sam"})

      {:ok, pct_member} = Lists.add_contact_to_list(pct, list)
      {:ok, underscore_member} = Lists.add_contact_to_list(underscore, list)
      {:ok, _plain_member} = Lists.add_contact_to_list(plain, list)

      pct_uuids = list |> Lists.list_members(search: "%") |> Enum.map(& &1.uuid)
      assert pct_uuids == [pct_member.uuid]

      underscore_uuids = list |> Lists.list_members(search: "_") |> Enum.map(& &1.uuid)
      assert underscore_uuids == [underscore_member.uuid]
    end
  end

  describe "counter maintenance" do
    test "subscriber_count increments on add and decrements on remove" do
      list = list_fixture()
      c1 = contact_fixture()
      c2 = contact_fixture()

      {:ok, m1} = Lists.add_contact_to_list(c1, list)
      assert Lists.get_list!(list.uuid).subscriber_count == 1

      {:ok, _m2} = Lists.add_contact_to_list(c2, list)
      assert Lists.get_list!(list.uuid).subscriber_count == 2

      {:ok, _} = Lists.remove_from_list(m1)
      assert Lists.get_list!(list.uuid).subscriber_count == 1
    end

    test "recount_list/1 repairs a drifted counter" do
      list = list_fixture()
      contact = contact_fixture()
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      # corrupt the cache directly, bypassing the context
      from(l in ContactList, where: l.uuid == ^list.uuid)
      |> Repo.update_all(set: [subscriber_count: 999])

      assert Lists.get_list!(list.uuid).subscriber_count == 999
      recounted = Lists.recount_list(Lists.get_list!(list.uuid))
      assert recounted.subscriber_count == 1
      assert Lists.get_list!(list.uuid).subscriber_count == 1
    end

    test "removing a pending member (never counted) does not drift the counter negative" do
      contact = contact_fixture()
      list = list_fixture()

      pending =
        %ListMember{}
        |> ListMember.changeset(%{
          "list_uuid" => list.uuid,
          "contact_uuid" => contact.uuid,
          "status" => "pending",
          "source" => "form"
        })
        |> Repo.insert!()

      assert Lists.get_list!(list.uuid).subscriber_count == 0
      assert {:ok, removed} = Lists.remove_from_list(pending)
      assert removed.status == "removed"
      assert Lists.get_list!(list.uuid).subscriber_count == 0
    end
  end

  describe "locale_apply_preview/1" do
    test "zero/zero when the list has no locale set" do
      list = list_fixture()
      contact = contact_fixture()
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      assert Lists.locale_apply_preview(list) == %{
               total: 0,
               missing_locale: 0,
               different_locale: 0
             }
    end

    test "counts subscribed members, split into missing-locale and different-locale subsets" do
      list = list_fixture(%{"locale" => "en"})

      no_locale = contact_fixture(%{"locale" => nil})
      same_locale = contact_fixture(%{"locale" => "en"})
      different_locale = contact_fixture(%{"locale" => "de"})
      {:ok, _} = Lists.add_contact_to_list(no_locale, list)
      {:ok, _} = Lists.add_contact_to_list(same_locale, list)
      {:ok, _} = Lists.add_contact_to_list(different_locale, list)

      # A removed member doesn't count — only "subscribed" is targeted.
      removed_contact = contact_fixture(%{"locale" => "de"})
      {:ok, removed_member} = Lists.add_contact_to_list(removed_contact, list)
      {:ok, _} = Lists.remove_from_list(removed_member)

      assert Lists.locale_apply_preview(list) == %{
               total: 3,
               missing_locale: 1,
               different_locale: 1
             }
    end
  end

  describe "apply_locale_to_members/3" do
    test "returns an error when the list has no locale set" do
      list = list_fixture()
      assert Lists.apply_locale_to_members(list, :all) == {:error, :no_locale}
    end

    test ":missing_only writes the list's locale onto contacts with no locale, leaves others alone" do
      list = list_fixture(%{"locale" => "en"})

      no_locale = contact_fixture(%{"locale" => nil})
      blank_locale = contact_fixture(%{"locale" => ""})
      different_locale = contact_fixture(%{"locale" => "de"})
      {:ok, _} = Lists.add_contact_to_list(no_locale, list)
      {:ok, _} = Lists.add_contact_to_list(blank_locale, list)
      {:ok, _} = Lists.add_contact_to_list(different_locale, list)

      assert {:ok, 2} = Lists.apply_locale_to_members(list, :missing_only)

      assert Contacts.get_contact(no_locale.uuid).locale == "en"
      assert Contacts.get_contact(blank_locale.uuid).locale == "en"
      assert Contacts.get_contact(different_locale.uuid).locale == "de"
    end

    test ":all overwrites every subscribed member's locale, including a different one" do
      list = list_fixture(%{"locale" => "en"})

      no_locale = contact_fixture(%{"locale" => nil})
      different_locale = contact_fixture(%{"locale" => "de"})
      {:ok, _} = Lists.add_contact_to_list(no_locale, list)
      {:ok, _} = Lists.add_contact_to_list(different_locale, list)

      assert {:ok, 2} = Lists.apply_locale_to_members(list, :all)

      assert Contacts.get_contact(no_locale.uuid).locale == "en"
      assert Contacts.get_contact(different_locale.uuid).locale == "en"
    end

    test "only touches subscribed members, not removed ones" do
      list = list_fixture(%{"locale" => "en"})
      contact = contact_fixture(%{"locale" => nil})
      {:ok, member} = Lists.add_contact_to_list(contact, list)
      {:ok, _} = Lists.remove_from_list(member)

      assert {:ok, 0} = Lists.apply_locale_to_members(list, :all)
      assert Contacts.get_contact(contact.uuid).locale == nil
    end

    test "a contact in multiple lists ends up with whichever list applied its locale last" do
      list_a = list_fixture(%{"locale" => "en"})
      list_b = list_fixture(%{"locale" => "de"})
      contact = contact_fixture(%{"locale" => nil})
      {:ok, _} = Lists.add_contact_to_list(contact, list_a)
      {:ok, _} = Lists.add_contact_to_list(contact, list_b)

      assert {:ok, 1} = Lists.apply_locale_to_members(list_a, :all)
      assert Contacts.get_contact(contact.uuid).locale == "en"

      assert {:ok, 1} = Lists.apply_locale_to_members(list_b, :all)
      assert Contacts.get_contact(contact.uuid).locale == "de"
    end

    test "logs one activity entry per call with the affected count" do
      list = list_fixture(%{"locale" => "en"})
      contact = contact_fixture(%{"locale" => nil})
      {:ok, _} = Lists.add_contact_to_list(contact, list)
      actor_uuid = Ecto.UUID.generate()

      assert {:ok, 1} =
               Lists.apply_locale_to_members(list, :missing_only, actor_uuid: actor_uuid)

      assert_activity_logged("crm.list_locale_applied",
        resource_uuid: list.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "does not log when nothing was updated" do
      list = list_fixture(%{"locale" => "en"})
      contact = contact_fixture(%{"locale" => "en"})
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      assert {:ok, 0} = Lists.apply_locale_to_members(list, :missing_only)
      refute_activity_logged("crm.list_locale_applied", resource_uuid: list.uuid)
    end
  end

  # ── Contact-level opt-out / consent ──────────────────────────────────

  describe "opt_out/2 and opt_in/2" do
    test "opt_out sets opted_out_at and appends a consent entry" do
      contact = contact_fixture()
      actor_uuid = Ecto.UUID.generate()

      assert {:ok, %Contact{} = updated} =
               Lists.opt_out(contact, source: "unsubscribe_link", actor_uuid: actor_uuid)

      assert updated.opted_out_at
      assert [%{"action" => "opt_out", "source" => "unsubscribe_link"}] = updated.consent["log"]
    end

    test "opt_out is idempotent (no duplicate consent entries)" do
      contact = contact_fixture()
      {:ok, once} = Lists.opt_out(contact)
      assert {:ok, twice} = Lists.opt_out(once)
      assert length(twice.consent["log"]) == 1
    end

    test "opt_in clears opted_out_at and appends a consent entry" do
      contact = contact_fixture()
      {:ok, opted_out} = Lists.opt_out(contact)

      assert {:ok, opted_in} = Lists.opt_in(opted_out)
      refute opted_in.opted_out_at
      actions = Enum.map(opted_in.consent["log"], & &1["action"])
      assert actions == ["opt_out", "opt_in"]
    end

    test "opt_in is idempotent when never opted out" do
      contact = contact_fixture()
      assert {:ok, ^contact} = Lists.opt_in(contact)
    end

    test "opt_out and opt_in broadcast :contact_opt_out / :contact_opt_in with contact_uuid" do
      contact = contact_fixture()
      contact_uuid = contact.uuid

      PubSub.subscribe(PubSub.topic_lists())

      assert {:ok, opted_out} = Lists.opt_out(contact)

      # "crm:lists" is a real, global (non-sandboxed) PubSub topic shared by
      # every async test that mutates a list or contact consent — pin
      # contact_uuid to the value THIS test just produced instead of
      # capturing whatever arrives first.
      assert_receive {:crm, :contact_opt_out, %{contact_uuid: ^contact_uuid}}, 1000

      assert {:ok, _} = Lists.opt_in(opted_out)
      assert_receive {:crm, :contact_opt_in, %{contact_uuid: ^contact_uuid}}, 1000
    end
  end

  describe "list_overlap/1" do
    test "returns only contacts subscribed to every given list" do
      list_a = list_fixture()
      list_b = list_fixture()
      list_c = list_fixture()

      both = contact_fixture()
      only_a = contact_fixture()
      all_three = contact_fixture()

      {:ok, _} = Lists.add_contact_to_list(both, list_a)
      {:ok, _} = Lists.add_contact_to_list(both, list_b)

      {:ok, _} = Lists.add_contact_to_list(only_a, list_a)

      {:ok, _} = Lists.add_contact_to_list(all_three, list_a)
      {:ok, _} = Lists.add_contact_to_list(all_three, list_b)
      {:ok, _} = Lists.add_contact_to_list(all_three, list_c)

      overlap_ab = Lists.list_overlap([list_a.uuid, list_b.uuid]) |> Enum.map(& &1.uuid)
      assert Enum.sort(overlap_ab) == Enum.sort([both.uuid, all_three.uuid])

      overlap_abc =
        Lists.list_overlap([list_a.uuid, list_b.uuid, list_c.uuid]) |> Enum.map(& &1.uuid)

      assert overlap_abc == [all_three.uuid]
    end

    test "a removed membership does not count toward the overlap" do
      list_a = list_fixture()
      list_b = list_fixture()
      contact = contact_fixture()

      {:ok, _} = Lists.add_contact_to_list(contact, list_a)
      {:ok, member_b} = Lists.add_contact_to_list(contact, list_b)
      {:ok, _} = Lists.remove_from_list(member_b)

      assert Lists.list_overlap([list_a.uuid, list_b.uuid]) == []
    end

    test "a duplicate list uuid in the input doesn't require an extra membership to match" do
      list_a = list_fixture()
      list_b = list_fixture()
      contact = contact_fixture()

      {:ok, _} = Lists.add_contact_to_list(contact, list_a)
      {:ok, _} = Lists.add_contact_to_list(contact, list_b)

      # list_a repeated: the "wanted" distinct-list count must dedup the
      # input, or this permanently requires one more distinct list_uuid per
      # membership than the contact could ever have.
      overlap =
        Lists.list_overlap([list_a.uuid, list_a.uuid, list_b.uuid]) |> Enum.map(& &1.uuid)

      assert overlap == [contact.uuid]
    end

    test "malformed uuids are dropped instead of raising an Ecto cast error" do
      list_a = list_fixture()
      list_b = list_fixture()
      contact = contact_fixture()

      {:ok, _} = Lists.add_contact_to_list(contact, list_a)
      {:ok, _} = Lists.add_contact_to_list(contact, list_b)

      assert Lists.list_overlap([list_a.uuid, "not-a-uuid", list_b.uuid])
             |> Enum.map(& &1.uuid) == [contact.uuid]

      # Fewer than 2 valid uuids left — no overlap to compute.
      assert Lists.list_overlap([list_a.uuid, "not-a-uuid"]) == []
    end

    test "trashed contacts are excluded from the overlap report" do
      list_a = list_fixture()
      list_b = list_fixture()
      contact = contact_fixture()

      {:ok, _} = Lists.add_contact_to_list(contact, list_a)
      {:ok, _} = Lists.add_contact_to_list(contact, list_b)

      assert Lists.list_overlap([list_a.uuid, list_b.uuid]) != []

      {:ok, _} = Contacts.trash_contact(contact)

      assert Lists.list_overlap([list_a.uuid, list_b.uuid]) == []
    end
  end

  # ── PubSub ──────────────────────────────────────────────────────────

  describe "PubSub broadcasts" do
    test "add_contact_to_list broadcasts :member_added with the updated counter" do
      PubSub.subscribe(PubSub.topic_lists())
      contact = contact_fixture()
      list = list_fixture()

      {:ok, member} = Lists.add_contact_to_list(contact, list)
      list_uuid = list.uuid
      member_uuid = member.uuid

      # See the comment on the reactivation test above re: pinning the
      # expected uuids (this topic is shared, non-sandboxed, global state)
      # and the generous timeout for scheduler jitter under that load.
      assert_receive {:crm, :member_added,
                      %{list_uuid: ^list_uuid, member_uuid: ^member_uuid, subscriber_count: 1}},
                     1000
    end

    test "remove_from_list broadcasts :member_removed with the decremented counter" do
      contact = contact_fixture()
      list = list_fixture()
      {:ok, member} = Lists.add_contact_to_list(contact, list)
      list_uuid = list.uuid

      PubSub.subscribe(PubSub.topic_lists())
      {:ok, _} = Lists.remove_from_list(member)

      assert_receive {:crm, :member_removed, %{list_uuid: ^list_uuid, subscriber_count: 0}}, 1000
    end

    test "create_list broadcasts :list_created" do
      PubSub.subscribe(PubSub.topic_lists())
      {:ok, list} = Lists.create_list(%{"name" => "Broadcast Me"})
      list_uuid = list.uuid

      assert_receive {:crm, :list_created, %{list_uuid: ^list_uuid}}, 1000
    end

    test "apply_locale_to_members broadcasts :list_locale_applied when it updates something" do
      list = list_fixture(%{"locale" => "en"})
      contact = contact_fixture(%{"locale" => nil})
      {:ok, _} = Lists.add_contact_to_list(contact, list)
      list_uuid = list.uuid

      PubSub.subscribe(PubSub.topic_lists())
      assert {:ok, 1} = Lists.apply_locale_to_members(list, :missing_only)

      assert_receive {:crm, :list_locale_applied,
                      %{
                        list_uuid: ^list_uuid,
                        locale: "en",
                        mode: :missing_only,
                        updated_count: 1
                      }},
                     1000
    end

    test "apply_locale_to_members does not broadcast when nothing was updated" do
      list = list_fixture(%{"locale" => "en"})
      contact = contact_fixture(%{"locale" => "en"})
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      PubSub.subscribe(PubSub.topic_lists())
      assert {:ok, 0} = Lists.apply_locale_to_members(list, :missing_only)

      refute_receive {:crm, :list_locale_applied, _}, 200
    end
  end
end
