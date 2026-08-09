defmodule PhoenixKitCRM.Web.ListFormLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Lists

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  test "renders the new list form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/crm/lists/new")
    assert html =~ "New list"
  end

  test "the way back is the chrome breadcrumb (page_section), not an in-body header",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/lists/new")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm/lists']", "Lists")
    refute html =~ "<h1"
    refute html =~ "<header"
  end

  test "creating a list persists it, auto-generates the slug, and logs the actor",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/new")

    view |> form("#crm-list-form", list: %{name: "Product Updates"}) |> render_submit()

    assert [list] = Enum.filter(Lists.list_lists(), &(&1.name == "Product Updates"))
    assert list.slug == "product-updates"

    assert_activity_logged("crm.list_created",
      resource_uuid: list.uuid,
      actor_uuid: scope.user.uuid
    )
  end

  test "editing a list updates it", %{conn: conn} do
    {:ok, list} = Lists.create_list(%{"name" => "Original", "slug" => "original"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/edit")
    view |> form("#crm-list-form", list: %{name: "Renamed"}) |> render_submit()

    assert Lists.get_list!(list.uuid).name == "Renamed"
  end

  test "the locale field is a select, not a free-text input", %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/lists/new")

    assert has_element?(view, "select[name='list[locale]']")
    assert html =~ "Not set"
  end

  test "setting a locale persists it", %{conn: conn} do
    {:ok, list} = Lists.create_list(%{"name" => "Original", "slug" => "original"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/edit")
    view |> form("#crm-list-form", list: %{locale: "de-DE"}) |> render_submit()

    assert Lists.get_list!(list.uuid).locale == "de-DE"
  end

  # Regression test: the Subscribable checkbox previously had no hidden
  # "false" fallback input, so an unchecked box was omitted entirely from a
  # real browser's form submission — Ecto.Changeset.cast/3 never saw the key
  # and the flag silently stayed on. The rendered DOM must reflect an actual
  # unchecked state before submit (not just an omitted key in the test's
  # override map) for this to exercise the same path a real browser would.
  test "unchecking Subscribable and saving actually clears the flag", %{conn: conn} do
    {:ok, list} =
      Lists.create_list(%{"name" => "Original", "slug" => "original", "subscribable" => true})

    assert Lists.get_list!(list.uuid).subscribable

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/edit")

    # Uncheck it (mirrors a real click) before submitting, so the hidden
    # fallback — not an explicit override — is what supplies "false".
    view
    |> form("#crm-list-form", list: %{subscribable: false})
    |> render_change()

    view
    |> form("#crm-list-form", list: %{name: "Renamed"})
    |> render_submit()

    refute Lists.get_list!(list.uuid).subscribable
  end
end
