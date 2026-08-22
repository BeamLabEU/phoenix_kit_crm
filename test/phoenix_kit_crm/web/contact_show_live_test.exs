defmodule PhoenixKitCRM.Web.ContactShowLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Contacts

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the contact's name", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}")

    assert html =~ "Grace Hopper"
  end

  test "redirects to the contacts list for an unknown uuid", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, "/en/admin/crm/contacts/#{Ecto.UUID.generate()}")

    assert to =~ "/admin/crm/contacts"
  end

  test "has a chrome breadcrumb back to Contacts (the rich in-body header stays, on purpose)",
       %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm/contacts']", "Contacts")
  end

  # `Andi.CRMBridge` is not a dependency of this package (Andi depends on CRM,
  # never the reverse) — this suite's own compile/test run never has it
  # loaded, so these two only exercise the "unavailable" branch of the guard.
  # The "available" branch (a real order rendering with a working row-link
  # into `/admin/andi/orders/:uuid/edit`) was verified separately by invoking
  # `ContactShowLive.render/1` directly inside the running Andi app against a
  # real order — see the crm-fix-spec.md Batch G execution notes.
  test "the show strip is core nav_tabs (border) with prefixed patch hrefs", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}")

    assert html =~ ~s(role="tablist")
    assert html =~ "tabs-border"
    assert has_element?(view, "a.tab-active", "Overview")

    assert has_element?(
             view,
             ~s{a[href="/en/admin/crm/contacts/#{contact.uuid}?tab=interactions"]},
             "Interactions"
           )
  end

  test "has no Orders tab when the host app's order bridge is unavailable", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}")

    refute has_element?(view, "a[href$='?tab=orders']")
  end

  test "clamps an explicit ?tab=orders back to Overview when the order bridge is unavailable",
       %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=orders")

    assert has_element?(view, "a.tab-active", "Overview")
  end
end
