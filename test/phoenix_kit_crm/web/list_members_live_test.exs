defmodule PhoenixKitCRM.Web.ListMembersLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.{Contacts, Lists}

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  defp list_fixture(attrs \\ %{}) do
    {:ok, list} =
      Lists.create_list(
        Map.merge(
          %{"name" => "Newsletter", "slug" => "list-#{System.unique_integer([:positive])}"},
          attrs
        )
      )

    list
  end

  defp contact_fixture(attrs \\ %{}) do
    {:ok, contact} =
      Contacts.create_contact(
        Map.merge(%{"name" => "Jane Trader", "email" => unique_email()}, attrs)
      )

    contact
  end

  defp unique_email, do: "member-#{System.unique_integer([:positive])}@example.com"

  test "renders the list name and existing members", %{conn: conn} do
    list = list_fixture(%{"name" => "Beta Testers"})
    contact = contact_fixture(%{"name" => "Alice Wonder"})
    {:ok, _} = Lists.add_contact_to_list(contact, list)

    {:ok, _view, html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

    assert html =~ "Beta Testers"
    assert html =~ "Alice Wonder"
  end

  test "the list name lives in the chrome assign, not a duplicate in-body heading",
       %{conn: conn} do
    list = list_fixture(%{"name" => "Beta Testers"})

    {:ok, view, html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

    assert html =~ ~s(id="test-page-title")
    refute html =~ "<h1"
    refute has_element?(view, "h1")
    assert has_element?(view, "#test-page-section[href='/en/admin/crm/lists']", "Lists")
  end

  test "adding a new contact by email creates a contact + membership and logs the actor",
       %{conn: conn, scope: scope} do
    list = list_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

    view
    |> form("#crm-list-add-member-form",
      add_member: %{email: "new@example.com", name: "New Person", locale: "en"}
    )
    |> render_submit()

    [member] = Lists.list_members(list)
    assert member.email == "new@example.com"
    assert member.contact.name == "New Person"
    assert member.source == "manual"

    assert_activity_logged("crm.list_member_added",
      resource_uuid: member.uuid,
      actor_uuid: scope.user.uuid
    )
  end

  test "live email check shows an 'already in this list' hint and blocks submit", %{conn: conn} do
    list = list_fixture()
    contact = contact_fixture(%{"email" => "taken@example.com"})
    {:ok, _} = Lists.add_contact_to_list(contact, list)

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

    html =
      view
      |> form("#crm-list-add-member-form", add_member: %{email: "taken@example.com"})
      |> render_change()

    assert html =~ "Already in this list"

    view
    |> form("#crm-list-add-member-form", add_member: %{email: "taken@example.com"})
    |> render_submit()

    # blocked: still just the one original member, no second contact created
    assert length(Lists.list_members(list)) == 1
  end

  test "the Resubscribe affordance reactivates a removed member instead of creating a new contact",
       %{conn: conn} do
    list = list_fixture()
    contact = contact_fixture(%{"email" => "removed@example.com"})
    {:ok, member} = Lists.add_contact_to_list(contact, list)
    {:ok, _} = Lists.remove_from_list(member)

    contact_count_before = length(Contacts.list_contacts())

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

    html =
      view
      |> form("#crm-list-add-member-form", add_member: %{email: "removed@example.com"})
      |> render_change()

    assert html =~ "Previously unsubscribed"

    view |> element("button[phx-click='resubscribe']") |> render_click()

    [reactivated] = Lists.list_members(list)
    assert reactivated.uuid == member.uuid
    assert reactivated.status == "subscribed"
    assert length(Contacts.list_contacts()) == contact_count_before
  end

  test "the per-row Resubscribe button (removed members table) reactivates the same membership",
       %{conn: conn} do
    list = list_fixture()
    contact = contact_fixture(%{"email" => "row-removed@example.com"})
    {:ok, member} = Lists.add_contact_to_list(contact, list)
    {:ok, _} = Lists.remove_from_list(member)

    contact_count_before = length(Contacts.list_contacts())

    {:ok, view, html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")
    assert html =~ "Resubscribe"

    view
    |> element("button[phx-click='resubscribe_row'][phx-value-contact_uuid='#{contact.uuid}']")
    |> render_click()

    [reactivated] = Lists.list_members(list)
    assert reactivated.uuid == member.uuid
    assert reactivated.status == "subscribed"
    assert length(Contacts.list_contacts()) == contact_count_before
  end

  test "removing a member flips its status without deleting the row", %{conn: conn} do
    list = list_fixture()
    contact = contact_fixture()
    {:ok, member} = Lists.add_contact_to_list(contact, list)

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

    view
    |> element("button[phx-click='remove_member'][phx-value-uuid='#{member.uuid}']")
    |> render_click()

    assert Lists.list_members(list, status: "removed") |> length() == 1
    refute Lists.subscribed?(contact, list)
  end

  describe "search" do
    test "narrows the table to matches by email or contact name", %{conn: conn} do
      list = list_fixture()
      alice = contact_fixture(%{"name" => "Alice Wonder", "email" => "alice@example.com"})
      bob = contact_fixture(%{"name" => "Bob Builder", "email" => "bob@example.com"})
      {:ok, _} = Lists.add_contact_to_list(alice, list)
      {:ok, _} = Lists.add_contact_to_list(bob, list)

      {:ok, view, html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")
      assert html =~ "Alice Wonder"
      assert html =~ "Bob Builder"

      # <.search_toolbar>'s input's phx-change fires from inside the
      # component's wrapping <form> (on_submit="search") — Phoenix LiveView's
      # client JS requires a phx-change input to be inside a <form> at all
      # (a bare input outside any <form> throws "form events require the
      # input to be inside a form" and never reaches the server). Targeting
      # the input directly (not the form itself, which only carries
      # phx-submit) exercises the same structural path a real browser
      # keystroke would.
      html =
        view
        |> element("form[phx-submit='search'] input[name='search']")
        |> render_change(%{"search" => "alice"})

      assert html =~ "Alice Wonder"
      refute html =~ "Bob Builder"
    end

    test "matches by contact name too, not just email", %{conn: conn} do
      list = list_fixture()
      alice = contact_fixture(%{"name" => "Alice Wonder", "email" => "alice@example.com"})
      bob = contact_fixture(%{"name" => "Bob Builder", "email" => "bob@example.com"})
      {:ok, _} = Lists.add_contact_to_list(alice, list)
      {:ok, _} = Lists.add_contact_to_list(bob, list)

      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

      html =
        view
        |> element("form[phx-submit='search'] input[name='search']")
        |> render_change(%{"search" => "wonder"})

      assert html =~ "Alice Wonder"
      refute html =~ "Bob Builder"
    end
  end

  describe "locale" do
    test "the members table shows each member's contact locale, dash when blank", %{conn: conn} do
      list = list_fixture()
      alice = contact_fixture(%{"name" => "Alice Wonder", "locale" => "de-DE"})
      bob = contact_fixture(%{"name" => "Bob Builder"})
      {:ok, _} = Lists.add_contact_to_list(alice, list)
      {:ok, _} = Lists.add_contact_to_list(bob, list)

      {:ok, _view, html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

      assert html =~ "de-DE"
      assert html =~ "Locale"
    end

    test "the manual add-by-email form accepts a locale", %{conn: conn} do
      list = list_fixture()
      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

      view
      |> form("#crm-list-add-member-form",
        add_member: %{"email" => "new@example.com", "name" => "New Person", "locale" => "fr"}
      )
      |> render_submit()

      [member] = Lists.list_members(list)
      assert member.contact.locale == "fr"
    end
  end

  describe "pagination" do
    # Regression: String.to_integer/1 raises on anything non-numeric, so a
    # fat-fingered bookmark or a crawler hitting ?page=abc used to crash
    # this LiveView outright — mount must survive and fall back to page 1.
    test "a non-numeric ?page= param doesn't crash the mount, falls back to page 1",
         %{conn: conn} do
      list = list_fixture()
      contact = contact_fixture(%{"name" => "Solo Member"})
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      for bad <- ["abc", "", "1.5", "1abc", "-1e5"] do
        assert {:ok, _view, html} =
                 live(conn, "/en/admin/crm/lists/#{list.uuid}/members?page=#{bad}")

        assert html =~ "Solo Member"
      end
    end

    # This page has no COUNT-backed total_pages (it peeks at limit+1 to
    # derive has_more?), so a huge out-of-range page can't be clamped against
    # a known last page — it comes back empty. Falling back to page 1 instead
    # of just showing an empty table is the same "don't strand the user on a
    # dead page" fix as contacts/companies get from real clamping.
    test "a huge page number with no results falls back to page 1's members",
         %{conn: conn} do
      list = list_fixture()
      contact = contact_fixture(%{"name" => "Solo Member"})
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      {:ok, _view, html} =
        live(conn, "/en/admin/crm/lists/#{list.uuid}/members?page=9999999999")

      assert html =~ "Solo Member"
    end
  end

  describe "apply list locale to contacts" do
    test "the toolbar button is disabled when the list has no locale", %{conn: conn} do
      list = list_fixture()
      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

      assert has_element?(view, "button[disabled]", "Apply list locale to contacts")
    end

    test "the toolbar button is enabled when the list has a locale", %{conn: conn} do
      list = list_fixture(%{"locale" => "en"})
      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

      refute has_element?(view, "button[disabled]", "Apply list locale to contacts")
    end

    # Regression: the modal used to always show `total` ("2 subscribed
    # contacts will be affected") regardless of the selected mode — wrong
    # for the default "missing_only" mode, which only actually touches the
    # subset with no locale yet. The displayed count must match what
    # apply_locale_to_members/3 will actually update for the CURRENT mode.
    test "opening the modal (default 'missing_only' mode) previews only the count that mode would touch",
         %{conn: conn} do
      list = list_fixture(%{"locale" => "en"})
      no_locale = contact_fixture(%{"locale" => nil})
      different_locale = contact_fixture(%{"locale" => "de"})
      {:ok, _} = Lists.add_contact_to_list(no_locale, list)
      {:ok, _} = Lists.add_contact_to_list(different_locale, list)

      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")

      html = view |> element("button", "Apply list locale to contacts") |> render_click()

      assert html =~ "1 subscribed contact will be affected"
      assert html =~ "1 contact already has a different locale set and will be left unchanged"
    end

    test "switching to 'all' mode updates the previewed count to the full total",
         %{conn: conn} do
      list = list_fixture(%{"locale" => "en"})
      no_locale = contact_fixture(%{"locale" => nil})
      different_locale = contact_fixture(%{"locale" => "de"})
      {:ok, _} = Lists.add_contact_to_list(no_locale, list)
      {:ok, _} = Lists.add_contact_to_list(different_locale, list)

      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")
      view |> element("button", "Apply list locale to contacts") |> render_click()

      html = view |> element("input[phx-value-mode='all']") |> render_click()

      assert html =~ "2 subscribed contacts will be affected"
      assert html =~ "1 of them already has a different locale set — it will be overwritten"
    end

    test "'only contacts without a locale' mode leaves an existing locale alone",
         %{conn: conn} do
      list = list_fixture(%{"locale" => "en"})
      no_locale = contact_fixture(%{"locale" => nil})
      different_locale = contact_fixture(%{"locale" => "de"})
      {:ok, _} = Lists.add_contact_to_list(no_locale, list)
      {:ok, _} = Lists.add_contact_to_list(different_locale, list)

      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")
      view |> element("button", "Apply list locale to contacts") |> render_click()

      html = view |> element("#crm-list-locale-modal .btn-primary") |> render_click()

      assert html =~ "Locale applied to 1 contact"
      assert Contacts.get_contact(no_locale.uuid).locale == "en"
      assert Contacts.get_contact(different_locale.uuid).locale == "de"
    end

    test "'all' mode overwrites every subscribed member's locale", %{conn: conn} do
      list = list_fixture(%{"locale" => "en"})
      no_locale = contact_fixture(%{"locale" => nil})
      different_locale = contact_fixture(%{"locale" => "de"})
      {:ok, _} = Lists.add_contact_to_list(no_locale, list)
      {:ok, _} = Lists.add_contact_to_list(different_locale, list)

      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")
      view |> element("button", "Apply list locale to contacts") |> render_click()
      view |> element("input[phx-value-mode='all']") |> render_click()

      html = view |> element("#crm-list-locale-modal .btn-primary") |> render_click()

      assert html =~ "Locale applied to 2 contacts"
      assert Contacts.get_contact(no_locale.uuid).locale == "en"
      assert Contacts.get_contact(different_locale.uuid).locale == "en"
    end

    test "cancel closes the modal without applying anything", %{conn: conn} do
      list = list_fixture(%{"locale" => "en"})
      contact = contact_fixture(%{"locale" => nil})
      {:ok, _} = Lists.add_contact_to_list(contact, list)

      {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/members")
      view |> element("button", "Apply list locale to contacts") |> render_click()
      view |> element("#crm-list-locale-modal .btn-ghost") |> render_click()

      assert Contacts.get_contact(contact.uuid).locale == nil
    end
  end
end
