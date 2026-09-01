defmodule PhoenixKitCRM.Web.ContactsLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Contacts

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  test "lists active contacts", %{conn: conn} do
    {:ok, _contact} = Contacts.create_contact(%{"name" => "Ada Lovelace"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/contacts")

    assert html =~ "Ada Lovelace"
  end

  test "the page title lives in the chrome assign, not a duplicate in-body heading",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/contacts")

    # page_title flows to the host app's chrome breadcrumb (out of the
    # LiveView body) — this repo's test layout stands in for that with
    # #test-page-title, so this only proves it's ASSIGNED, not duplicated
    # by an in-body <h1>/<.admin_page_header title=...> as well.
    assert html =~ ~s(id="test-page-title")
    refute html =~ "<h1"
    refute has_element?(view, "h1")
  end

  test "New contact is reachable in the table's toolbar, not a page-level header",
       %{conn: conn} do
    {:ok, _contact} = Contacts.create_contact(%{"name" => "Ada Lovelace"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts")

    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts/new"]}, "New contact")
  end

  test "the filter strip is core nav_tabs (border) offering only filters with results", %{
    conn: conn
  } do
    {:ok, supplier} = Contacts.create_contact(%{"name" => "Supplier Sam"})
    {:ok, _} = PhoenixKitCRM.PartyRoles.grant_role(supplier, "supplier")
    {:ok, _} = Contacts.create_contact(%{"name" => "Plain Pam"})

    {:ok, view, html} = live(conn, "/en/admin/crm/contacts")

    assert html =~ ~s(role="tablist")
    assert html =~ "tabs-border"
    # Same strip rules as the companies index: honest "All" default,
    # counts on every label, no dead filters.
    assert has_element?(view, "a.tab-active", "All (2)")

    assert has_element?(
             view,
             ~s{a[href="/en/admin/crm/contacts?filter=supplier"]},
             "Suppliers (1)"
           )

    refute has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=customer"]})
    refute has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=manufacturer"]})
    refute has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=partner"]})
    refute has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=trashed"]})
    refute has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=active"]})
  end

  test "the Active/Inactive pair appears once an inactive contact exists, and Inactive scopes by status",
       %{conn: conn} do
    {:ok, _} = Contacts.create_contact(%{"name" => "Awake Anna"})
    {:ok, _} = Contacts.create_contact(%{"name" => "Dormant Dora", "status" => "inactive"})

    {:ok, view, html} = live(conn, "/en/admin/crm/contacts")

    assert html =~ "Awake Anna"
    assert html =~ "Dormant Dora"
    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=active"]}, "Active (1)")

    assert has_element?(
             view,
             ~s{a[href="/en/admin/crm/contacts?filter=inactive"]},
             "Inactive (1)"
           )

    {:ok, _view, html} = live(conn, "/en/admin/crm/contacts?filter=inactive")
    assert html =~ "Dormant Dora"
    refute html =~ "Awake Anna"
    assert html =~ "1 inactive contact"
  end

  test "the Trashed tab appears once a contact is in the trash", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "To Be Trashed"})
    {:ok, _} = Contacts.trash_contact(contact)

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts")

    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=trashed"]})
  end

  test "trashing a contact moves it to trash and logs crm.contact_trashed",
       %{conn: conn, scope: scope} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "To Be Trashed"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts")

    # toggleable table_default keeps both the table-view and card-view rows
    # in the DOM at once (CSS-hidden, not removed) — scope to the
    # table-view copy (id_suffix "table") so the selector matches exactly
    # one element.
    view
    |> element(~s{#crm-contact-menu-table-#{contact.uuid} [phx-click="trash"]})
    |> render_click()

    assert Contacts.get_contact(contact.uuid).status == "trashed"

    assert_activity_logged("crm.contact_trashed",
      resource_uuid: contact.uuid,
      actor_uuid: scope.user.uuid
    )
  end

  describe "pagination" do
    test "more than a page of contacts splits across pages, newest page reachable via ?page=2",
         %{conn: conn} do
      # 26 contacts, one over the page size — "Contact 01".."Contact 26" sort
      # in that order by name, so page 1 (25) holds 01..25 and page 2 holds
      # just 26.
      for n <- 1..26 do
        {:ok, _} =
          Contacts.create_contact(%{"name" => "Contact #{String.pad_leading("#{n}", 2, "0")}"})
      end

      {:ok, view, html} = live(conn, "/en/admin/crm/contacts")
      assert html =~ "Contact 01"
      assert html =~ "Contact 25"
      refute html =~ "Contact 26"
      # real total-count pagination (not the has_more?/peek trick) — the
      # toolbar count must reflect all 26, not just this page's 25.
      assert html =~ "26 contacts"
      assert has_element?(view, "a", "2")

      {:ok, _view2, html2} = live(conn, "/en/admin/crm/contacts?page=2")
      refute html2 =~ "Contact 01"
      assert html2 =~ "Contact 26"
    end

    test "no pagination controls render when everything fits on one page", %{conn: conn} do
      {:ok, _} = Contacts.create_contact(%{"name" => "Solo Contact"})

      {:ok, view, _html} = live(conn, "/en/admin/crm/contacts")

      refute has_element?(view, "a", "2")
    end

    # Regression: String.to_integer/1 raises on anything non-numeric, so a
    # fat-fingered bookmark or a crawler hitting ?page=abc used to crash
    # this LiveView outright — mount must survive and fall back to page 1.
    test "a non-numeric ?page= param doesn't crash the mount, falls back to page 1",
         %{conn: conn} do
      {:ok, _} = Contacts.create_contact(%{"name" => "Solo Contact"})

      for bad <- ["abc", "", "1.5", "1abc", "-1e5", "0"] do
        assert {:ok, _view, html} = live(conn, "/en/admin/crm/contacts?page=#{bad}")
        assert html =~ "Solo Contact"
      end
    end

    test "a page past the last one clamps down to the real last page instead of showing empty",
         %{conn: conn} do
      {:ok, _} = Contacts.create_contact(%{"name" => "Solo Contact"})

      {:ok, _view, html} = live(conn, "/en/admin/crm/contacts?page=999")

      assert html =~ "Solo Contact"
      refute html =~ "No contacts yet."
      refute html =~ "No contacts on this page."
    end

    # With more than one real page, the clamp must land on the ACTUAL last
    # page (2, holding "Contact 26"), not just fall back to page 1 — this is
    # also the exact shape of the reported OOM crash
    # (GET /admin/crm/contacts?page=9999999999): a huge, out-of-range page
    # number against a small total_pages must resolve to real data, not an
    # empty page or a runaway range.
    test "a huge page number clamps to the real last page, not page 1", %{conn: conn} do
      for n <- 1..26 do
        {:ok, _} =
          Contacts.create_contact(%{"name" => "Contact #{String.pad_leading("#{n}", 2, "0")}"})
      end

      {:ok, _view, html} = live(conn, "/en/admin/crm/contacts?page=9999999999")

      refute html =~ "Contact 01"
      assert html =~ "Contact 26"
    end
  end

  describe "search" do
    test "narrows the table by name or email and combines with pagination", %{conn: conn} do
      {:ok, _} =
        Contacts.create_contact(%{"name" => "Alice Wonder", "email" => "a@example.com"})

      {:ok, _} =
        Contacts.create_contact(%{"name" => "Bob Builder", "email" => "wonder@bob.example"})

      {:ok, _} = Contacts.create_contact(%{"name" => "Carol Danvers"})

      {:ok, view, html} = live(conn, "/en/admin/crm/contacts")
      assert html =~ "Alice Wonder"
      assert html =~ "Bob Builder"
      assert html =~ "Carol Danvers"

      html =
        view
        |> element("form[phx-submit='search'] input[name='search']")
        |> render_change(%{"search" => "wonder"})

      assert html =~ "Alice Wonder"
      assert html =~ "Bob Builder"
      refute html =~ "Carol Danvers"
      assert html =~ "2 contacts"
    end

    test "combines with a role tab (search only within the current filter)", %{conn: conn} do
      _alice = contact_with_role("Alice Wonder", "supplier")
      _bob = contact_with_role("Bob Wonder", "customer")

      {:ok, view, html} = live(conn, "/en/admin/crm/contacts?filter=supplier")
      assert html =~ "Alice Wonder"
      refute html =~ "Bob Wonder"

      html =
        view
        |> element("form[phx-submit='search'] input[name='search']")
        |> render_change(%{"search" => "wonder"})

      assert html =~ "Alice Wonder"
      refute html =~ "Bob Wonder"
    end
  end

  defp contact_with_role(name, role) do
    {:ok, contact} = Contacts.create_contact(%{"name" => name})
    {:ok, _} = PhoenixKitCRM.PartyRoles.grant_role(contact, role)
    contact
  end
end
