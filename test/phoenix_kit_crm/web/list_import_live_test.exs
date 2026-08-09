defmodule PhoenixKitCRM.Web.ListImportLiveTest do
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

  test "renders the paste and upload input sections", %{conn: conn} do
    list = list_fixture(%{"name" => "Beta Testers"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    assert html =~ "Beta Testers"
    assert html =~ "Paste emails"
    assert html =~ "Upload a file"
  end

  test "the way back is the chrome breadcrumb, pointing at THIS list's members (not Lists)",
       %{conn: conn} do
    list = list_fixture(%{"name" => "Beta Testers"})

    {:ok, view, html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    assert has_element?(
             view,
             "#test-page-section[href='/en/admin/crm/lists/#{list.uuid}/members']",
             "Beta Testers"
           )

    refute html =~ "<h1"
    refute html =~ "<header"
  end

  test "previewing pasted emails shows counts and writes nothing to the database", %{conn: conn} do
    list = list_fixture()
    contact_count_before = length(Contacts.list_contacts())

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    html =
      view
      |> form("#crm-import-paste-form", paste: %{text: "good@example.com\nnot-an-email\n"})
      |> render_submit()

    assert html =~ "nothing has been imported yet"
    assert html =~ "good@example.com"
    assert Lists.list_members(list) == []
    assert length(Contacts.list_contacts()) == contact_count_before
  end

  test "full flow via paste: preview -> confirm -> done renders the report", %{
    conn: conn,
    scope: scope
  } do
    list = list_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    view
    |> form("#crm-import-paste-form", paste: %{text: "one@example.com\ntwo@example.com\n"})
    |> render_submit()

    view |> element("button[phx-click='confirm_import']") |> render_click()
    html = render(view)

    assert html =~ "Imported 2 contacts"
    members = Lists.list_members(list)
    assert length(members) == 2

    assert_activity_logged("crm.list_member_added",
      resource_uuid: hd(members).uuid,
      actor_uuid: scope.user.uuid
    )
  end

  test "upload path: a small CSV file imports via LiveViewTest file_input", %{conn: conn} do
    list = list_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    file =
      file_input(view, "#crm-import-upload-form", :file, [
        %{
          name: "contacts.csv",
          content: "email,name\nalice@example.com,Alice\nbob@example.com,Bob\n",
          type: "text/csv"
        }
      ])

    assert render_upload(file, "contacts.csv") =~ ~s(value="100")

    html = view |> form("#crm-import-upload-form") |> render_submit()
    assert html =~ "contacts.csv"
    assert html =~ "alice@example.com"

    view |> element("button[phx-click='confirm_import']") |> render_click()
    html = render(view)

    assert html =~ "Imported 2 contacts"
    assert length(Lists.list_members(list)) == 2
  end

  test "submitting preview_upload before the upload finishes doesn't crash and consumes nothing",
       %{conn: conn} do
    list = list_fixture()
    contact_count_before = length(Contacts.list_contacts())

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    file =
      file_input(view, "#crm-import-upload-form", :file, [
        %{
          name: "contacts.csv",
          content: "email,name\nalice@example.com,Alice\nbob@example.com,Bob\n",
          type: "text/csv"
        }
      ])

    # Only 50% chunked — the entry isn't done? yet. The submit button's
    # disabled= is client-side only; a direct "preview_upload" event here
    # simulates bypassing it (devtools, a forged socket message) while the
    # upload is mid-flight.
    refute render_upload(file, "contacts.csv", 50) =~ ~s(value="100")

    html = view |> form("#crm-import-upload-form") |> render_submit()

    assert Process.alive?(view.pid)
    assert html =~ "Upload still in progress"
    assert html =~ "Upload a file"
    assert Lists.list_members(list) == []
    assert length(Contacts.list_contacts()) == contact_count_before
  end

  test "the report breaks skips out by bucket: already_in_list, invalid_email, no_email, duplicate_in_file",
       %{conn: conn} do
    list = list_fixture()

    {:ok, existing} =
      Contacts.create_contact(%{"name" => "Existing", "email" => "existing@example.com"})

    {:ok, _} = Lists.add_contact_to_list(existing, list)

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    text = """
    existing@example.com
    not-an-email

    dup@example.com
    dup@example.com
    """

    view
    |> form("#crm-import-paste-form", paste: %{text: text})
    |> render_submit()

    view |> element("button[phx-click='confirm_import']") |> render_click()
    html = render(view)

    assert html =~ "Already in list"
    assert html =~ "Invalid email"
    assert html =~ "Duplicate in file"
    assert html =~ "existing@example.com"
    assert html =~ "dup@example.com"
  end

  test "back_to_input returns to the input phase without importing anything", %{conn: conn} do
    list = list_fixture()
    contact_count_before = length(Contacts.list_contacts())

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    view
    |> form("#crm-import-paste-form", paste: %{text: "someone@example.com\n"})
    |> render_submit()

    html = view |> element("button[phx-click='back_to_input']") |> render_click()

    assert html =~ "Paste emails"
    assert length(Contacts.list_contacts()) == contact_count_before
  end

  test "pasting blank text flashes 'No rows found' and stays on the input phase", %{conn: conn} do
    list = list_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    html =
      view
      |> form("#crm-import-paste-form", paste: %{text: "   \n\n  "})
      |> render_submit()

    assert html =~ "No rows found in that input"
    assert html =~ "Paste emails"
  end

  test "uploading a file over the size limit shows the too_large error", %{conn: conn} do
    list = list_fixture()

    {:ok, view, _html} = live(conn, "/en/admin/crm/lists/#{list.uuid}/import")

    # LiveViewTest requires the content's actual byte size to match the
    # declared entry size, so the file really is over the 5MB limit here.
    content = String.duplicate("a", 6_000_000)

    file =
      file_input(view, "#crm-import-upload-form", :file, [
        %{name: "huge.csv", content: content, type: "text/csv"}
      ])

    render_upload(file, "huge.csv")

    assert render(view) =~ "File is too large (max 5 MB)"
  end
end
