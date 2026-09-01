defmodule PhoenixKitCRM.Web.ContactShowLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Attachments, Contacts, Interactions}

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  # The Files tab rolls up files attached to the contact's interactions and
  # was loaded once; an interaction added or deleted elsewhere changed the
  # list and its count without the tab noticing.
  test "the Files tab's interaction roll-up follows interactions changed elsewhere",
       %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Anna Files"})

    {:ok, view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=files")
    refute html =~ "Attached to interactions"

    # An interaction with an attachment, created from the contact's other
    # session: the folder + file rows core's Storage would write.
    {:ok, interaction} =
      Interactions.create_interaction(%{
        "contact_uuid" => contact.uuid,
        "interaction_type" => "note",
        "subject" => "Sent the quote",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, uploader} =
      Auth.register_user(%{
        "email" => "uploader-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    {:ok, folder} =
      Storage.create_folder(%{"name" => Attachments.interaction_folder_name(interaction.uuid)})

    {:ok, _file} =
      Storage.create_file(%{
        "original_file_name" => "quote.pdf",
        "file_name" => "quote.pdf",
        "mime_type" => "application/pdf",
        "file_type" => "document",
        "ext" => "pdf",
        "file_checksum" => "abc",
        "user_file_checksum" => "abc",
        "size" => 12,
        "status" => "active",
        "user_uuid" => uploader.uuid,
        "folder_uuid" => folder.uuid
      })

    # The interaction broadcast (create fires it) is what reaches the page.
    PhoenixKitCRM.PubSub.broadcast_interaction(:interaction_created, interaction)

    html = render(view)
    assert html =~ "Attached to interactions"
    assert html =~ "quote.pdf"
  end

  test "a company-anchored interaction spilling in via party is read-only on the contact page",
       %{conn: conn} do
    {:ok, company} = PhoenixKitCRM.Companies.create_company(%{"name" => "Anchor Co"})
    {:ok, anna} = Contacts.create_contact(%{"name" => "Party Anna"})

    {:ok, spilled} =
      Interactions.create_interaction(
        %{
          "company_uuid" => company.uuid,
          "interaction_type" => "meeting",
          "subject" => "Site visit at Anchor Co",
          "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
        },
        [%{raw_name: "Party Anna", contact_uuid: anna.uuid}]
      )

    {:ok, view, html} =
      live(conn, "/en/admin/crm/contacts/#{anna.uuid}?tab=interactions")

    # The row shows, names its company anchor, and offers no delete — it is
    # managed from the company's page.
    assert html =~ "Site visit at Anchor Co"
    assert has_element?(view, ~s{a[href="/en/admin/crm/companies/#{company.uuid}"]}, "Anchor Co")

    refute has_element?(
             view,
             ~s{button[phx-click=delete_interaction][phx-value-uuid="#{spilled.uuid}"]}
           )

    # And a forged delete event is refused by the handler's ownership gate.
    view
    |> with_target("#crm-interactions-#{anna.uuid}")
    |> render_click("delete_interaction", %{"uuid" => spilled.uuid})

    assert Interactions.get_interaction(spilled.uuid)
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
