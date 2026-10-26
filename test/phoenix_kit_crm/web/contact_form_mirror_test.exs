defmodule PhoenixKitCRM.Web.ContactFormMirrorTest do
  @moduledoc """
  LiveView integration tests for the mirror panel/picker/conflict flow
  wired into `ContactFormLive` (Task H) — the structural twin of
  `CompanyFormMirrorTest`, reusing the exact controlled-choices +
  fresh-diff-at-resolve pattern. Also pins the pre-existing `allow_login`
  checkbox/`apply_login/4` path, which had zero test coverage before this
  file (flagged in Task G's review) — a regression there would otherwise
  slip through unnoticed while this panel work lands next to it.
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.Test.SiteOwner

  # The site's Owner exists before the test's own users (see SiteOwner).
  setup do
    _owner = SiteOwner.ensure!()
    :ok
  end

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Contacts

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

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
    {:ok, contact} = Contacts.create_contact(Map.merge(%{"name" => "Anna Kask"}, attrs))
    contact
  end

  defp edit(conn, contact), do: live(conn, "/en/admin/crm/contacts/#{contact.uuid}/edit")

  describe "mirror_create" do
    test "creates a mirror person-user and shows the linked state", %{conn: conn} do
      contact =
        contact_fixture(%{"name" => "Anna Kask", "email" => "anna-#{unique()}@example.test"})

      {:ok, view, _html} = edit(conn, contact)

      html = render_click(view, "mirror_create")

      assert html =~ "Anna"
      updated = Contacts.get_contact(contact.uuid)
      assert updated.user_uuid != nil
      assert Auth.get_user(updated.user_uuid).account_type == "person"
    end
  end

  describe "mirror_open_picker" do
    test "lists unlinked person-users only — a linked one and an organization user are excluded",
         %{conn: conn} do
      linked_user = person_user_fixture(%{"first_name" => "Linked#{unique()}"})
      linked_contact = contact_fixture(%{"name" => "Linked Contact"})
      {:ok, _} = Contacts.link_user(linked_contact, linked_user.uuid)

      unlinked_email = "unlinked-#{unique()}@example.test"
      _unlinked_user = person_user_fixture(%{"email" => unlinked_email})

      org_email = "org-picker-#{unique()}@example.test"
      _org_user = org_user_fixture(%{"email" => org_email})

      contact = contact_fixture(%{"name" => "Target"})
      {:ok, view, _html} = edit(conn, contact)

      html = render_click(view, "mirror_open_picker")

      assert html =~ unlinked_email
      refute html =~ linked_user.email
      refute html =~ org_email
    end
  end

  describe "the site's Owners and Admins" do
    defp admin_fixture do
      user = person_user_fixture(%{"email" => "admin-#{unique()}@example.test"})
      {:ok, _} = Roles.assign_role(user, "Admin")
      user
    end

    test "are never offered by the picker", %{conn: conn} do
      admin = admin_fixture()
      plain_email = "plain-#{unique()}@example.test"
      _plain = person_user_fixture(%{"email" => plain_email})

      {:ok, view, _html} = edit(conn, contact_fixture(%{"name" => "Target"}))
      html = render_click(view, "mirror_open_picker")

      assert html =~ plain_email
      refute html =~ admin.email
    end

    test "a crafted link to one is refused, in the page and in the context", %{conn: conn} do
      admin = admin_fixture()
      contact = contact_fixture(%{"name" => "Target", "email" => admin.email})

      {:ok, view, _html} = edit(conn, contact)
      html = render_submit(view, "mirror_link", %{"user_uuid" => admin.uuid})

      assert html =~ "cannot be linked"
      refute Contacts.get_contact(contact.uuid).user_uuid
      assert {:error, :privileged_account} = Contacts.link_user(contact, admin.uuid)
      assert {:error, :privileged_account} = Contacts.connect_user(contact, admin.email)
    end
  end

  describe "mirror_link — no conflict" do
    test "links directly and fills a CRM placeholder's BLANK first_name from the contact", %{
      conn: conn
    } do
      # Unlike organization accounts, first_name/last_name are NOT required
      # at registration (registration_changeset only length-validates
      # them), so a genuinely blank first_name on a real registered user
      # is realistic here — no post-hoc blanking needed (contrast with the
      # Company equivalent, which had to simulate it).
      email = "shared-#{unique()}@example.test"

      user =
        person_user_fixture(%{"email" => email, "custom_fields" => %{"source" => "crm_contact"}})

      contact = contact_fixture(%{"name" => "Anna Kask", "email" => email})

      user = as_unclaimed!(user)
      {:ok, view, _html} = edit(conn, contact)

      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
      updated_user = Auth.get_user(user.uuid)
      assert updated_user.first_name == "Anna"
      assert updated_user.last_name == "Kask"
      assert updated_user.email == email
    end

    test "links directly without touching a field that already matches", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Anna",
          "last_name" => "Kask"
        })

      {:ok, view, _html} = edit(conn, contact)

      html = render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      refute html =~ "Resolve differences"
      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
    end
  end

  describe "mirror_link — conflict" do
    test "a diverging name opens the conflict modal WITHOUT writing anything", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)

      html = render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      assert html =~ "Resolve differences"
      assert html =~ "Annie K."
      refute Contacts.get_contact(contact.uuid).user_uuid
    end

    test "resolving keep_crm writes the contact's name onto a CRM placeholder", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K.",
          "custom_fields" => %{"source" => "crm_contact"}
        })

      user = as_unclaimed!(user)
      {:ok, view, _html} = edit(conn, contact)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_crm"}})

      updated_user = Auth.get_user(user.uuid)
      assert updated_user.first_name == "Anna"
      assert updated_user.last_name == "Kask"
      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
    end

    test "resolving keep_user writes the user's joined name onto the contact", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_user"}})

      assert Contacts.get_contact(contact.uuid).name == "Annie K."
      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
    end

    # The resolution writes the contact, but the inputs on screen used to
    # keep the pre-resolution values — and Save, the next click, wrote them
    # straight back, undoing the resolution with no warning.
    test "after keep_user the Name input shows the resolved value and Save keeps it",
         %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)
      # An unsaved edit in an unrelated field, typed before the modal opens.
      render_change(view, "validate", %{
        "contact" => %{"name" => "Anna Kask", "notes" => "draft note"}
      })

      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      html = render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_user"}})

      assert html =~ ~s(value="Annie K.")
      refute html =~ ~s(value="Anna Kask")
      # The draft outside the resolved field is still there.
      assert html =~ "draft note"

      # Saving what is on screen must not revert the resolution.
      view
      |> form("form[phx-submit=save]")
      |> render_submit()

      assert Contacts.get_contact(contact.uuid).name == "Annie K."
    end

    test "cancel writes nothing to either side", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      render_click(view, "mirror_cancel_conflict")

      refute Contacts.get_contact(contact.uuid).user_uuid
      assert Contacts.get_contact(contact.uuid).name == "Anna Kask"
      updated_user = Auth.get_user(user.uuid)
      assert updated_user.first_name == "Annie"
      assert updated_user.last_name == "K."
    end

    test "a selection made in the modal survives an intervening unrelated re-render", %{
      conn: conn
    } do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      html =
        render_change(view, "mirror_choice_changed", %{"choices" => %{"name" => "keep_user"}})

      assert html =~ ~r/value="keep_user"[^>]*checked/

      # Unrelated re-render: the contact form's own "validate" handler.
      html = render_change(view, "validate", %{"contact" => %{"name" => "Anna Kask"}})

      assert html =~ ~r/value="keep_user"[^>]*checked/
      refute html =~ ~r/value="keep_crm"[^>]*checked/
    end

    test "a crafted mirror_choice_changed with a bogus field key is ignored, not crashed", %{
      conn: conn
    } do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      html =
        render_change(view, "mirror_choice_changed", %{
          "choices" => %{"bogus_field" => "keep_user", "name" => "keep_user"}
        })

      assert Process.alive?(view.pid)
      assert html =~ ~r/value="keep_user"[^>]*checked/
    end

    test "mirror_resolve recomputes diff fresh — a field no longer diverging at submit time is dropped",
         %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      # Out-of-band change: the contact's name is updated to match the
      # user's joined name WITHOUT going through this LiveView, so
      # socket.assigns.contact is now stale.
      {:ok, _} = Contacts.update_contact(contact, %{"name" => "Annie K."})

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_crm"}})

      updated_user = Auth.get_user(user.uuid)
      assert updated_user.first_name == "Annie"
      assert updated_user.last_name == "K."
    end
  end

  describe "a registered person's account is never rewritten" do
    test "the conflict modal says so, and keep_crm leaves the account exactly as it was",
         %{conn: conn} do
      shared_email = "real-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => shared_email})

      user =
        person_user_fixture(%{
          "email" => shared_email,
          "first_name" => "Annie",
          "last_name" => "K."
        })

      {:ok, view, _html} = edit(conn, contact)
      html = render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})
      assert html =~ ~s(data-testid="mirror-account-locked")

      html = render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_crm"}})

      after_user = Auth.get_user(user.uuid)
      assert after_user.first_name == "Annie"
      assert after_user.last_name == "K."
      assert after_user.email == shared_email
      # The CRM keeps its own value; the link is made; the person is told.
      assert Contacts.get_contact(contact.uuid).name == "Anna Kask"
      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
      assert html =~ "left unchanged"
    end

    test "a crafted keep_crm on an email conflict never changes the account's login email",
         %{conn: conn} do
      contact =
        contact_fixture(%{"name" => "Anna Kask", "email" => "crm-#{unique()}@example.test"})

      user = person_user_fixture(%{"first_name" => "Anna", "last_name" => "Kask"})

      {:ok, view, _html} = edit(conn, contact)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})
      render_submit(view, "mirror_resolve", %{"choices" => %{"email" => "keep_crm"}})

      assert Auth.get_user(user.uuid).email == user.email
      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
    end

    test "a no-conflict link leaves the account's blank name blank", %{conn: conn} do
      email = "blank-#{unique()}@example.test"
      user = person_user_fixture(%{"email" => email})
      contact = contact_fixture(%{"name" => "Anna Kask", "email" => email})

      {:ok, view, _html} = edit(conn, contact)
      html = render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      assert Contacts.get_contact(contact.uuid).user_uuid == user.uuid
      assert Auth.get_user(user.uuid).first_name in [nil, ""]
      assert html =~ "left unchanged"
    end
  end

  describe "mirror_unlink" do
    test "clears the link; the user row survives", %{conn: conn} do
      contact = contact_fixture()
      user = person_user_fixture()
      {:ok, _} = Contacts.link_user(contact, user.uuid)

      {:ok, view, _html} = edit(conn, contact)

      html = render_click(view, "mirror_unlink")

      refute html =~ "mirror_unlink"
      assert Contacts.get_contact(contact.uuid).user_uuid == nil
      assert Auth.get_user(user.uuid) != nil
    end
  end

  describe "allow_login checkbox (pre-existing path, characterized here — was untested)" do
    test "ticking allow_login with an email connects a user on save", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/new")

      email = "allow-login-#{unique()}@example.test"

      view
      |> form("form", contact: %{name: "New Person", email: email}, allow_login: "true")
      |> render_submit()

      assert [contact] = Enum.filter(Contacts.list_contacts(), &(&1.name == "New Person"))
      assert contact.user_uuid != nil
      assert Auth.get_user(contact.user_uuid).email == email
    end

    test "unticking allow_login disconnects an existing login on save", %{conn: conn} do
      email = "allow-login-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Has Login", "email" => email})
      user = person_user_fixture(%{"email" => email})
      {:ok, _} = Contacts.link_user(contact, user.uuid)

      {:ok, view, _html} = edit(conn, contact)

      view
      |> form("form", contact: %{name: "Has Login"}, allow_login: "false")
      |> render_submit()

      assert Contacts.get_contact(contact.uuid).user_uuid == nil
      # The user row survives — allow_login only unlinks, never deletes.
      assert Auth.get_user(user.uuid) != nil
    end

    test "toggling allow_login leaves the rest of the form (name, notes) intact", %{conn: conn} do
      email = "allow-login-#{unique()}@example.test"
      contact = contact_fixture(%{"name" => "Keep Me", "email" => email, "notes" => "important"})

      {:ok, view, _html} = edit(conn, contact)

      view
      |> form("form",
        contact: %{name: "Keep Me", email: email, notes: "important"},
        allow_login: "true"
      )
      |> render_submit()

      updated = Contacts.get_contact(contact.uuid)
      assert updated.name == "Keep Me"
      assert updated.notes == "important"
      assert updated.user_uuid != nil
    end
  end
end
