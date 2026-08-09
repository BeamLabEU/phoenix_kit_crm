defmodule PhoenixKitCRM.Web.ListsLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Lists

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
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

  test "lists active lists", %{conn: conn} do
    list_fixture(%{"name" => "VIP Customers"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/lists")

    assert html =~ "VIP Customers"
  end

  test "shows the list's locale, or a dash when it has none", %{conn: conn} do
    list_fixture(%{"name" => "With Locale", "locale" => "fr-FR"})
    list_fixture(%{"name" => "No Locale"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/lists")

    assert html =~ "fr-FR"
    assert html =~ "—"
  end

  test "the page title lives in the chrome assign, not a duplicate in-body heading",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/lists")

    assert html =~ ~s(id="test-page-title")
    refute html =~ "<h1"
    refute has_element?(view, "h1")
  end

  test "New list and Compare are reachable without a page-level header, in the table toolbar",
       %{conn: conn} do
    list_fixture()
    {:ok, view, _html} = live(conn, "/en/admin/crm/lists")

    assert has_element?(view, ~s{a[href="/en/admin/crm/lists/new"]}, "New list")
    assert has_element?(view, ~s{a[href="/en/admin/crm/comparison"]}, "Compare")
  end

  test "archived lists only show on the Archived tab", %{conn: conn} do
    list = list_fixture(%{"name" => "Old Campaign"})
    {:ok, _} = Lists.archive_list(list)

    {:ok, _view, html} = live(conn, "/en/admin/crm/lists")
    refute html =~ "Old Campaign"

    {:ok, _view, html} = live(conn, "/en/admin/crm/lists?filter=archived")
    assert html =~ "Old Campaign"
  end

  test "toggling subscribable flips the flag", %{conn: conn} do
    list = list_fixture(%{"subscribable" => false})

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists")
    view |> element("input[phx-value-uuid='#{list.uuid}']") |> render_click()

    assert Lists.get_list!(list.uuid).subscribable
  end

  test "archiving a list via the row menu action", %{conn: conn} do
    list = list_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists")

    view
    |> element("#crm-list-menu-table-#{list.uuid} button[phx-click='archive']")
    |> render_click()

    assert Lists.get_list!(list.uuid).status == "archived"
  end

  test "a list-scoped PubSub event from elsewhere still reloads this view", %{conn: conn} do
    list = list_fixture(%{"name" => "Live Update Me"})

    {:ok, view, html} = live(conn, "/en/admin/crm/lists")
    assert html =~ "Live Update Me"

    # Archiving via the context directly (not through this view's own
    # "archive" event handler) simulates another tab/session mutating the
    # same list — the view must pick it up purely through the :list_archived
    # broadcast on crm:lists.
    {:ok, _} = Lists.archive_list(list)

    refute render(view) =~ "Live Update Me"
  end

  test "a contact-scoped PubSub event (opt_out/opt_in) doesn't crash a mounted view", %{
    conn: conn
  } do
    list = list_fixture()
    {:ok, view, _html} = live(conn, "/en/admin/crm/lists")

    send(view.pid, {:crm, :contact_opt_out, %{contact_uuid: Ecto.UUID.generate()}})
    send(view.pid, {:crm, :contact_opt_in, %{contact_uuid: Ecto.UUID.generate()}})

    assert Process.alive?(view.pid)
    assert render(view) =~ list.name
  end
end
