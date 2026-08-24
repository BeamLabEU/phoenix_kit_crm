defmodule PhoenixKitCRM.ContactsMirrorTest do
  @moduledoc """
  Pins the Contact <-> person-User mirror context: the NEW explicit-panel
  actions (`link_user/2`, `create_mirror_user/1` — owner Q2 keeps these
  alongside the existing "allow login" checkbox) plus the EXISTING
  find-or-create path (`connect_user/2`), now retrofitted to be
  transactional (Task D review finding 2, applied here preemptively).
  Every fixture is a REAL persisted row — the pre-existing
  `ContactsTest.map_by_user_uuids/1` bug (linking to a random
  `Ecto.UUID.generate()` with no backing user row) is exactly the mistake
  this suite avoids.
  """

  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.Schemas.Contact

  defp unique, do: System.unique_integer([:positive])

  defp person_user_fixture(attrs \\ %{}) do
    base = %{"email" => "person-#{unique()}@example.test", "password" => "Sup3rSecret!24"}
    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
  end

  defp org_user_fixture(attrs \\ %{}) do
    base = %{
      "email" => "org-#{unique()}@example.test",
      "password" => "Sup3rSecret!24",
      "account_type" => "organization",
      "organization_name" => "Acme"
    }

    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
  end

  defp contact_fixture(attrs \\ %{}) do
    {:ok, contact} = Contacts.create_contact(Map.merge(%{"name" => "Test Contact"}, attrs))
    contact
  end

  describe "link_user/2" do
    test "links a chosen existing person user" do
      contact = contact_fixture()
      user = person_user_fixture()

      assert {:ok, linked} = Contacts.link_user(contact, user.uuid)
      assert linked.user_uuid == user.uuid
      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
    end

    test "rejects an organization-account user (:not_a_person); contact unchanged" do
      contact = contact_fixture()
      user = org_user_fixture()

      assert {:error, :not_a_person} = Contacts.link_user(contact, user.uuid)
      refute Contacts.get_contact(contact.uuid).user_uuid
    end

    test "rejects a uuid with no backing user row" do
      contact = contact_fixture()

      assert {:error, :user_not_found} = Contacts.link_user(contact, Ecto.UUID.generate())
      refute Contacts.get_contact(contact.uuid).user_uuid
    end

    test "rejects a user already linked to another contact — no crash" do
      user = person_user_fixture()
      first = contact_fixture(%{"name" => "First"})
      second = contact_fixture(%{"name" => "Second"})

      assert {:ok, _} = Contacts.link_user(first, user.uuid)
      assert {:error, %Ecto.Changeset{}} = Contacts.link_user(second, user.uuid)

      refute Contacts.get_contact(second.uuid).user_uuid
      assert Contacts.get_contact(first.uuid).user_uuid == user.uuid
    end

    test "re-linking an already-linked contact to a different user is a safe relink" do
      contact = contact_fixture()
      user_a = person_user_fixture()
      user_b = person_user_fixture()

      {:ok, _} = Contacts.link_user(contact, user_a.uuid)
      assert {:ok, relinked} = Contacts.link_user(contact, user_b.uuid)
      assert relinked.user_uuid == user_b.uuid
    end
  end

  describe "create_mirror_user/1" do
    test "creates a person user from the contact and links it atomically" do
      contact =
        contact_fixture(%{"name" => "Anna Kask", "email" => "anna-#{unique()}@example.test"})

      assert {:ok, {linked, user}} = Contacts.create_mirror_user(contact)

      assert linked.user_uuid == user.uuid
      assert user.account_type == "person"
      assert user.first_name == "Anna"
      assert user.last_name == "Kask"
      assert user.email == contact.email
      assert user.custom_fields["source"] == "crm_contact"
      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
    end

    test "rejects when the contact already has a mirror user — no new user is minted" do
      contact = contact_fixture()
      original_user = person_user_fixture()
      {:ok, linked} = Contacts.link_user(contact, original_user.uuid)

      assert {:error, :already_linked} = Contacts.create_mirror_user(linked)

      # The original link survives untouched — no relink, no orphan.
      assert Contacts.get_contact(contact.uuid).user_uuid == original_user.uuid
    end

    test "when Auth.register_user fails (duplicate email), the transaction rolls back cleanly" do
      taken_email = "taken-cmu-#{unique()}@example.test"
      _existing = person_user_fixture(%{"email" => taken_email})
      contact = contact_fixture(%{"name" => "Someone", "email" => taken_email})

      assert {:error, %Ecto.Changeset{}} = Contacts.create_mirror_user(contact)
      refute Contacts.get_contact(contact.uuid).user_uuid
    end

    test "a connect_user succeeds then link fails vector rolls back the created user" do
      # A contact struct with a uuid the DB has never seen makes the
      # `Repo.update` inside link_user fail hard (Ecto.StaleEntryError)
      # rather than a clean {:error, changeset} — the create_mirror_user
      # own already-linked guard rules out the natural unique-constraint
      # vector (a freshly-registered user's uuid can never already
      # collide), same reasoning as Companies.create_mirror_user/2's
      # rollback test. Proves nothing partial survives a failed link.
      email = "ghost-cmu-#{unique()}@example.test"
      ghost_contact = %Contact{uuid: Ecto.UUID.generate(), name: "Ghost", email: email}

      assert_raise Ecto.StaleEntryError, fn ->
        Contacts.create_mirror_user(ghost_contact)
      end

      refute Auth.get_user_by_email(email)
    end
  end

  describe "connect_user/2 — retrofitted to be transactional, same external behavior" do
    # The resolution runs in one transaction; the companies showing this
    # contact must hear about a rewritten name after the commit, once —
    # never from inside the transaction, never for a rollback.
    test "a resolution that rewrites the contact tells its companies once, after the commit" do
      {:ok, company} = PhoenixKitCRM.Companies.create_company(%{"name" => "Acme"})
      contact = contact_fixture(%{"name" => "Anna Kask"})
      {:ok, _} = Contacts.set_primary_company(contact, company.uuid, nil, nil)
      user = person_user_fixture(%{"first_name" => "Annie", "last_name" => "K."})

      # Subscribed after the fixture, so only the resolution's own message lands.
      PhoenixKitCRM.PubSub.subscribe(PhoenixKitCRM.PubSub.topic_company(company.uuid))

      deltas = %{crm: %{name: "Annie K."}, user: %{}}
      assert {:ok, {linked, _user}} = Contacts.apply_mirror_resolution(contact, user, deltas)
      assert linked.name == "Annie K."

      contact_uuid = contact.uuid
      assert_receive {:crm, :member_changed, %{contact_uuid: ^contact_uuid}}
      refute_receive {:crm, :member_changed, _}, 100
    end

    test "a resolution that leaves the contact untouched broadcasts nothing to its companies" do
      {:ok, company} = PhoenixKitCRM.Companies.create_company(%{"name" => "Acme"})
      contact = contact_fixture(%{"name" => "Anna Kask"})
      {:ok, _} = Contacts.set_primary_company(contact, company.uuid, nil, nil)
      user = person_user_fixture()

      PhoenixKitCRM.PubSub.subscribe(PhoenixKitCRM.PubSub.topic_company(company.uuid))

      assert {:ok, _} = Contacts.apply_mirror_resolution(contact, user, %{crm: %{}, user: %{}})
      refute_receive {:crm, :member_changed, _}, 100
    end

    test "finds an existing user by email and links (unchanged)" do
      contact = contact_fixture()
      user = person_user_fixture()

      assert {:ok, linked, :existing} = Contacts.connect_user(contact, user.email)
      assert linked.user_uuid == user.uuid
    end

    test "registers a placeholder when no user exists for the email (unchanged)" do
      contact = contact_fixture()
      email = "placeholder-#{unique()}@example.test"

      assert {:ok, linked, :created} = Contacts.connect_user(contact, email)
      assert linked.user_uuid != nil

      created = Auth.get_user_by_email(email)
      assert created.custom_fields["source"] == "crm_contact"
    end

    test "a blank email returns an error (unchanged)" do
      contact = contact_fixture()
      assert {:error, :blank_email} = Contacts.connect_user(contact, "")
    end

    test "re-connecting an already-linked contact to a different user is a safe relink (unchanged)" do
      contact = contact_fixture()
      user_a = person_user_fixture()
      user_b = person_user_fixture()

      {:ok, _, :existing} = Contacts.connect_user(contact, user_a.email)
      assert {:ok, relinked, :existing} = Contacts.connect_user(contact, user_b.email)
      assert relinked.user_uuid == user_b.uuid
    end

    test "atomicity: a just-registered placeholder is rolled back when the link fails hard" do
      # Same ghost-contact technique as create_mirror_user's rollback
      # test: find_or_create_user_by_email genuinely registers a NEW
      # placeholder for this brand-new email (nothing to find), then the
      # link step (Repo.update on a contact whose uuid the DB has never
      # seen) raises Ecto.StaleEntryError. Before the retrofit this
      # scenario was handled by a manual `if user_status == :created, do:
      # repo().delete(user)` — which never ran here because it lived in
      # `else`, not a rescue, so an exception would have skipped it
      # entirely and left the placeholder behind. The transaction wrap
      # makes that structurally impossible.
      email = "ghost-connect-#{unique()}@example.test"
      ghost_contact = %Contact{uuid: Ecto.UUID.generate(), name: "Ghost"}

      assert_raise Ecto.StaleEntryError, fn ->
        Contacts.connect_user(ghost_contact, email)
      end

      refute Auth.get_user_by_email(email)
    end
  end

  describe "apply_mirror_resolution/3" do
    test "rolls back the contact write when the subsequent user update fails" do
      # Mixed choice: BOTH deltas non-empty — the contact update runs
      # FIRST and succeeds; the user update runs SECOND and fails on a
      # duplicate-email unique violation (resolving an email conflict by
      # copying an email across can collide with an existing account).
      # The whole transaction — including the ALREADY-SUCCEEDED contact
      # write — must roll back.
      taken_email = "taken-amr-#{unique()}@example.test"
      _existing = person_user_fixture(%{"email" => taken_email})

      contact =
        contact_fixture(%{"name" => "Anna Kask", "email" => "anna-amr-#{unique()}@example.test"})

      user =
        person_user_fixture(%{
          "first_name" => "Annie",
          "last_name" => "K.",
          "email" => "user-amr-#{unique()}@example.test"
        })

      deltas = %{crm: %{name: "Annie K."}, user: %{email: taken_email}}

      assert {:error, %Ecto.Changeset{}} =
               Contacts.apply_mirror_resolution(contact, user, deltas)

      # The contact write did NOT survive.
      assert Contacts.get_contact(contact.uuid).name == "Anna Kask"
      # No partial link either.
      refute Contacts.get_contact(contact.uuid).user_uuid
      refute Auth.get_user(user.uuid).email == taken_email
    end

    test "applies both deltas and links when both writes succeed" do
      contact =
        contact_fixture(%{
          "name" => "Anna Kask",
          "email" => "anna-amr2-#{unique()}@example.test"
        })

      user =
        person_user_fixture(%{
          "first_name" => "Annie",
          "last_name" => "K.",
          "email" => "user-amr2-#{unique()}@example.test"
        })

      deltas = %{crm: %{name: "Annie K."}, user: %{email: "new-amr2-#{unique()}@example.test"}}

      assert {:ok, {linked_contact, linked_user}} =
               Contacts.apply_mirror_resolution(contact, user, deltas)

      assert linked_contact.name == "Annie K."
      assert linked_user.email == deltas.user.email
      assert linked_contact.user_uuid == user.uuid
    end
  end
end
