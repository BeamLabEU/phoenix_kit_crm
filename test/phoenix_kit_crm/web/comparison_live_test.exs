defmodule PhoenixKitCRM.Web.ComparisonLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.{Contacts, Lists}

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

  defp contact_fixture(attrs \\ %{}) do
    {:ok, contact} =
      Contacts.create_contact(
        Map.merge(%{"name" => "Jane Trader", "email" => unique_email()}, attrs)
      )

    contact
  end

  defp unique_email, do: "cmp-#{System.unique_integer([:positive])}@example.com"

  test "renders empty states when there are no duplicates or lists", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/crm/comparison")

    assert html =~ "No duplicate emails found."
    assert html =~ "No active lists yet."
  end

  test "the way back is the chrome breadcrumb (page_section), not an in-body header",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/comparison")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm/lists']", "Lists")
    refute html =~ "<h1"
    refute html =~ "<header"
  end

  test "shows duplicate email groups with a count and expands to reveal the contacts",
       %{conn: conn} do
    email = unique_email()
    c1 = contact_fixture(%{"name" => "Alice One", "email" => email})
    c2 = contact_fixture(%{"name" => "Alice Two", "email" => String.upcase(email)})
    _unique = contact_fixture(%{"name" => "Solo Contact"})

    {:ok, view, html} = live(conn, "/en/admin/crm/comparison")

    assert html =~ email
    assert html =~ "2 contacts"
    refute html =~ c1.name

    expanded = view |> element("input[phx-value-email='#{email}']") |> render_click()

    assert expanded =~ c1.name
    assert expanded =~ c2.name
  end

  test "list overlap: fewer than 2 selected shows guidance, 2+ shows the intersection",
       %{conn: conn} do
    list_a = list_fixture(%{"name" => "List A"})
    list_b = list_fixture(%{"name" => "List B"})
    both = contact_fixture(%{"name" => "In Both"})
    only_a = contact_fixture(%{"name" => "Only A"})

    {:ok, _} = Lists.add_contact_to_list(both, list_a)
    {:ok, _} = Lists.add_contact_to_list(both, list_b)
    {:ok, _} = Lists.add_contact_to_list(only_a, list_a)

    {:ok, view, html} = live(conn, "/en/admin/crm/comparison")
    assert html =~ "Select at least 2 lists to compare."

    view |> element("input[phx-value-uuid='#{list_a.uuid}']") |> render_click()
    html = view |> element("input[phx-value-uuid='#{list_b.uuid}']") |> render_click()

    assert html =~ "In Both"
    refute html =~ "Only A"
    assert html =~ "1 contact in common"
  end

  test "unselecting back down to fewer than 2 lists clears the overlap result", %{conn: conn} do
    list_a = list_fixture()
    list_b = list_fixture()
    contact = contact_fixture()
    {:ok, _} = Lists.add_contact_to_list(contact, list_a)
    {:ok, _} = Lists.add_contact_to_list(contact, list_b)

    {:ok, view, _html} = live(conn, "/en/admin/crm/comparison")

    view |> element("input[phx-value-uuid='#{list_a.uuid}']") |> render_click()
    view |> element("input[phx-value-uuid='#{list_b.uuid}']") |> render_click()
    html = view |> element("input[phx-value-uuid='#{list_b.uuid}']") |> render_click()

    assert html =~ "Select at least 2 lists to compare."
  end
end
