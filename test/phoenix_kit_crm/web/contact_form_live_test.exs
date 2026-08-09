defmodule PhoenixKitCRM.Web.ContactFormLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Contacts

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  test "renders the new contact form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/crm/contacts/new")
    assert html =~ "Name"
  end

  test "the way back is the chrome breadcrumb (page_section), not an in-body header",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/contacts/new")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm/contacts']", "Contacts")
    refute html =~ "<h1"
    refute html =~ "<header"
  end

  test "creating a contact persists it and logs crm.contact_created with the actor",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/new")

    view
    |> form("form", contact: %{name: "New Person", email: "new@example.com"})
    |> render_submit()

    assert [contact] = Enum.filter(Contacts.list_contacts(), &(&1.name == "New Person"))

    assert_activity_logged("crm.contact_created",
      resource_uuid: contact.uuid,
      actor_uuid: scope.user.uuid
    )
  end

  test "submitting a blank name re-renders with a validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/new")

    html = view |> form("form", contact: %{name: ""}) |> render_submit()

    assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    assert Contacts.list_contacts() == []
  end

  test "editing a contact updates it", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Original Name"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}/edit")

    view |> form("form", contact: %{name: "Renamed"}) |> render_submit()

    assert Contacts.get_contact(contact.uuid).name == "Renamed"
  end

  describe "locale" do
    test "creating a contact with a locale persists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/new")

      view
      |> form("form", contact: %{name: "New Person", email: "new@example.com", locale: "de-DE"})
      |> render_submit()

      assert [contact] = Enum.filter(Contacts.list_contacts(), &(&1.name == "New Person"))
      assert contact.locale == "de-DE"
    end

    test "editing a contact's locale updates it, and the current value is pre-filled",
         %{conn: conn} do
      {:ok, contact} = Contacts.create_contact(%{"name" => "Has Locale", "locale" => "en"})

      {:ok, view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}/edit")
      assert html =~ ~s(value="en")

      view |> form("form", contact: %{locale: "fr"}) |> render_submit()

      assert Contacts.get_contact(contact.uuid).locale == "fr"
    end

    test "an invalid locale format re-renders with a validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/new")

      html =
        view
        |> form("form", contact: %{name: "Bad Locale", locale: "not a locale!"})
        |> render_submit()

      assert html =~ "must be a valid locale format"
      assert Contacts.list_contacts() == []
    end
  end
end
