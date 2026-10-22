defmodule PhoenixKitCRM.Web.ContactShowLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Attachments, Contacts, Interactions}

  defmodule OrdersBridge do
    def orders_for_contact(_contact) do
      [%{number: 4711, path: "/host/orders/1", inserted_at: ~U[2026-01-02 03:04:05Z]}]
    end
  end

  defmodule RaisingBridge do
    def orders_for_contact(_contact), do: raise("boom")
  end

  defp put_bridge(mod) do
    previous = Application.get_env(:phoenix_kit_crm, :orders_bridge)
    Application.put_env(:phoenix_kit_crm, :orders_bridge, mod)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_crm, :orders_bridge, previous),
        else: Application.delete_env(:phoenix_kit_crm, :orders_bridge)
    end)
  end

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

    # The parent queues send_update while handling the broadcast. The first
    # render synchronizes with the parent; the next observes that update.
    render(view)
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
    assert has_element?(view, ~s{a[href="#{admin()}/crm/companies/#{company.uuid}"]}, "Anchor Co")

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

  test "the trail is CRM / Contacts / <contact> (the rich in-body header stays, on purpose)",
       %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}")

    assert has_element?(view, "#test-page-section[href='#{admin()}/crm']", "CRM")
    assert has_element?(view, "#test-page-crumbs a[href='#{admin()}/crm/contacts']", "Contacts")
    assert has_element?(view, "#test-page-title", "Grace Hopper")
  end

  test "the edit page's trail is the contact page's trail plus the contact", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}/edit")

    assert has_element?(view, "#test-page-section[href='#{admin()}/crm']", "CRM")
    assert has_element?(view, "#test-page-crumbs a[href='#{admin()}/crm/contacts']", "Contacts")

    assert has_element?(
             view,
             "#test-page-crumbs a[href='#{admin()}/crm/contacts/#{contact.uuid}']",
             "Grace Hopper"
           )

    assert has_element?(view, "#test-page-title", "Edit")
  end

  test "the show strip is core nav_tabs (border) with prefixed patch hrefs", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

    {:ok, view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}")

    assert html =~ ~s(role="tablist")
    assert html =~ "tabs-border"
    assert has_element?(view, "a.tab-active", "Overview")

    assert has_element?(
             view,
             ~s{a[href="#{admin()}/crm/contacts/#{contact.uuid}?tab=interactions"]},
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

  describe "configured orders bridge" do
    test "shows the Orders tab with the bridge's rows", %{conn: conn} do
      put_bridge(OrdersBridge)
      {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

      {:ok, view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=orders")

      assert has_element?(view, "a[href$='?tab=orders']")
      assert html =~ "#4711"
      assert html =~ "2026-01-02"
      assert html =~ "/host/orders/1"
    end

    test "a bridge that raises leaves the tab empty and the page rendered", %{conn: conn} do
      put_bridge(RaisingBridge)
      {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

      {:ok, view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=orders")

      assert has_element?(view, "a[href$='?tab=orders']")
      assert html =~ "No orders yet"
    end

    test "a configured module that is not loadable hides the tab", %{conn: conn} do
      put_bridge(Does.Not.Exist)
      {:ok, contact} = Contacts.create_contact(%{"name" => "Grace Hopper"})

      {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}")

      refute has_element?(view, "a[href$='?tab=orders']")
    end
  end
end
