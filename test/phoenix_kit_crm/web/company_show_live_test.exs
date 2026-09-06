defmodule PhoenixKitCRM.Web.CompanyShowLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Contacts, Interactions}

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp unique, do: System.unique_integer([:positive])

  # LiveViewTest does not expose assigns. The connected process is the
  # LiveView itself (`%Socket{}`) or a Channel wrapping one.
  defp live_assigns(view) do
    case :sys.get_state(view.pid) do
      %{assigns: assigns} -> assigns
      %{socket: %{assigns: assigns}} -> assigns
      other -> flunk("cannot read LiveView assigns from #{inspect(other)}")
    end
  end

  defp org_user_fixture(attrs) do
    base = %{
      "email" => "org-#{unique()}@example.test",
      "password" => "Sup3rSecret!24",
      "account_type" => "organization",
      "organization_name" => "Acme #{unique()}"
    }

    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
  end

  test "the header band is gone: Edit is the layout's action chip, identity opens Overview",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Chipset Co"})
    {:ok, _} = PhoenixKitCRM.PartyRoles.grant_role(company, "supplier")

    {:ok, view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    # Edit reaches the layout as the breadcrumb action chip, not an in-body
    # button — the band that held only logo + status + Edit is deleted.
    assert has_element?(
             view,
             ~s{#test-page-action[href="/en/admin/crm/companies/#{company.uuid}/edit"]},
             "Edit company"
           )

    refute has_element?(view, ~s{a.btn[href="/en/admin/crm/companies/#{company.uuid}/edit"]})

    # The identity block (status + role badges) opens the Overview tab instead.
    assert html =~ "Supplier"
  end

  # ── Live refresh ──────────────────────────────────────────────────
  #
  # Everything on this page used to be loaded once in handle_params: a
  # contact joining, leaving or being trashed elsewhere, or a member's
  # interaction, showed up only after a reload.

  defp member_fixture(company, name) do
    {:ok, contact} = Contacts.create_contact(%{"name" => name})
    {:ok, _} = Contacts.set_primary_company(contact, company.uuid, "CTO", nil)
    contact
  end

  test "the Members tab follows contacts joining, leaving and being trashed elsewhere",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    anna = member_fixture(company, "Anna Member")

    {:ok, view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=members")
    assert html =~ "(1)"
    assert html =~ "Anna Member"

    # Joins from the contact edit page (another session).
    _bert = member_fixture(company, "Bert Member")
    html = render(view)
    assert html =~ "Bert Member"
    assert html =~ "(2)"

    # Trashed from the contacts index.
    {:ok, _} = Contacts.trash_contact(anna)
    html = render(view)
    refute html =~ "Anna Member"
    assert html =~ "(1)"
  end

  test "renaming a member elsewhere updates the Members tab", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    bert = member_fixture(company, "Bert Member")

    {:ok, view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=members")
    assert html =~ "Bert Member"

    {:ok, _} = Contacts.update_contact(bert, %{"name" => "Bertram Member"})

    html = render(view)
    assert html =~ "Bertram Member"
    refute html =~ "Bert Member"
  end

  test "a member's new interaction refreshes the Interactions rollup", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    member = member_fixture(company, "Anna Member")

    {:ok, view, html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    refute html =~ "Called about the invoice"

    {:ok, _} =
      Interactions.create_interaction(%{
        "contact_uuid" => member.uuid,
        "interaction_type" => "note",
        "subject" => "Called about the invoice",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert render(view) =~ "Called about the invoice"
  end

  test "the catalogue topic is followed on the HOST PubSub, where the catalogue broadcasts" do
    # PhoenixKit.PubSubHelper resolves the host server; the catalogue's
    # Catalogue.PubSub.broadcast/3 publishes there. A subscription on core's
    # internal server (CRM's own topics) never hears it.
    :ok = PhoenixKitCRM.PubSub.subscribe_host("phoenix_kit_catalogue")
    uuid = Ecto.UUID.generate()

    PhoenixKit.PubSubHelper.broadcast(
      "phoenix_kit_catalogue",
      {:catalogue_data_changed, :item_supplier_info, uuid, nil}
    )

    assert_receive {:catalogue_data_changed, :item_supplier_info, ^uuid, nil}

    :ok = PhoenixKitCRM.PubSub.unsubscribe_host("phoenix_kit_catalogue")

    PhoenixKit.PubSubHelper.broadcast(
      "phoenix_kit_catalogue",
      {:catalogue_data_changed, :item, uuid, nil}
    )

    refute_receive {:catalogue_data_changed, :item, _, _}, 100
  end

  test "a catalogue change message is ignored when the catalogue is not available",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    send(view.pid, {:catalogue_data_changed, :item_supplier_info, Ecto.UUID.generate(), nil})

    assert render(view) =~ "Initech"
  end

  # ── Every tab says what it shows and how something gets into it ────
  #
  # Each tab is fed from somewhere else (a contact's form, a member's
  # interaction log, the catalogue's item form, the activity log); an empty
  # tab used to read as broken.

  test "the Members tab explains membership and links to a prefilled new-contact form",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=members")

    assert html =~ "A contact joins from its own form"
    assert html =~ ~s(href="/en/admin/crm/contacts/new?company_uuid=#{company.uuid}")
    assert html =~ "New contact for this company"
    assert html =~ "set the Company field on an existing contact"
  end

  test "the Interactions tab has a company composer that logs a company-anchored interaction",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    # The composer stamps the acting user as owner — a persisted one, or the
    # owner FK (rightly) refuses the insert.
    user = org_user_fixture(%{})
    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))

    {:ok, view, html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    # The composer works with zero members — that is the whole point of
    # company-anchored interactions.
    assert html =~ "Log an interaction with Initech"

    view
    |> element("form[phx-change=composer_change]")
    |> render_change(%{"interaction" => %{"subject" => "Front desk call"}})

    view |> element("button[phx-click=save_interaction]") |> render_click()

    assert [interaction] = Interactions.list_for_company(company.uuid)
    assert interaction.company_uuid == company.uuid
    assert interaction.contact_uuid == nil
    assert interaction.subject == "Front desk call"
    assert interaction.owner_user_uuid == user.uuid
    assert render(view) =~ "Front desk call"
  end

  test "the composer reads and shows times in the viewer's zone, per date, not today's offset",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    user = org_user_fixture(%{})
    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, user_timezone: "Europe/Tallinn"))

    {:ok, view, html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    # The "When" prefill is now in Tallinn, not UTC — whichever season it is.
    prefill =
      DateTime.utc_now()
      |> PhoenixKit.Utils.Date.format_datetime_local("Europe/Tallinn")
      |> String.slice(0, 13)

    assert html =~ ~s(value="#{prefill}), "prefill hour in the viewer's zone"

    # Tallinn is UTC+2 in January and UTC+3 in July: a typed 10:00 must store
    # the instant of ITS date. Whichever season the suite runs in, one of the
    # two would be an hour off under a today's-offset conversion.
    for {typed, stored} <- [
          {"2026-01-15T10:00", ~U[2026-01-15 08:00:00Z]},
          {"2026-07-15T10:00", ~U[2026-07-15 07:00:00Z]}
        ] do
      view
      |> element("form[phx-change=composer_change]")
      |> render_change(%{"interaction" => %{"subject" => typed, "occurred_at" => typed}})

      view |> element("button[phx-click=save_interaction]") |> render_click()

      assert [%{occurred_at: ^stored, time_zone: "Europe/Tallinn"}] =
               Enum.filter(Interactions.list_for_company(company.uuid), &(&1.subject == typed)),
             "#{typed} stored as #{inspect(stored)} in the viewer's zone"

      # ...and it renders back as the wall clock that was typed
      assert render(view) =~ String.replace(typed, "T", " ")
    end
  end

  test "a When value that cannot be read is a save error, not a silent now", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    user = org_user_fixture(%{})
    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, user_timezone: "Europe/Tallinn"))

    {:ok, view, _html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    view
    |> element("form[phx-change=composer_change]")
    |> render_change(%{
      "interaction" => %{"subject" => "Typed junk", "occurred_at" => "yesterday"}
    })

    html = view |> element("button[phx-click=save_interaction]") |> render_click()

    assert html =~ "The time could not be read."
    assert Interactions.list_for_company(company.uuid) == []
  end

  test "the Interactions tab merges company and member rows with provenance, scope filter splits them",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    anna = member_fixture(company, "Anna Member")

    {:ok, _own} =
      Interactions.create_interaction(%{
        "company_uuid" => company.uuid,
        "interaction_type" => "call",
        "subject" => "Company-level call",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, _member_own} =
      Interactions.create_interaction(%{
        "contact_uuid" => anna.uuid,
        "interaction_type" => "note",
        "subject" => "Anna's own note",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, view, html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    # Default :all — both rows, each with provenance (Company badge / name link).
    assert html =~ "Company-level call"
    assert html =~ "Anna&#39;s own note"
    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts/#{anna.uuid}"]}, "Anna Member")

    html = view |> element("button[phx-value-scope=company]") |> render_click()
    assert html =~ "Company-level call"
    refute html =~ "Anna&#39;s own note"

    html = view |> element("button[phx-value-scope=members]") |> render_click()
    refute html =~ "Company-level call"
    assert html =~ "Anna&#39;s own note"
  end

  test "a member's own interaction is read-only on the company page — delete only for company-anchored rows",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    anna = member_fixture(company, "Anna Member")

    {:ok, own} =
      Interactions.create_interaction(%{
        "company_uuid" => company.uuid,
        "interaction_type" => "call",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, member_own} =
      Interactions.create_interaction(%{
        "contact_uuid" => anna.uuid,
        "interaction_type" => "note",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, view, _html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    assert has_element?(
             view,
             ~s{button[phx-click=delete_interaction][phx-value-uuid="#{own.uuid}"]}
           )

    refute has_element?(
             view,
             ~s{button[phx-click=delete_interaction][phx-value-uuid="#{member_own.uuid}"]}
           )

    # A forged delete for the member's row is refused by the handler's
    # ownership gate too — the missing button is not the only defense.
    view
    |> with_target("#crm-company-interactions-#{company.uuid}")
    |> render_click("delete_interaction", %{"uuid" => member_own.uuid})

    assert Interactions.get_interaction(member_own.uuid)
  end

  test "Events, Files, Images and Comments tabs each carry their intro", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    base = "/en/admin/crm/companies/#{company.uuid}"

    {:ok, _view, html} = live(conn, base <> "?tab=events")
    assert html =~ "recorded automatically"

    # Files / Images / Comments only render when their modules are on;
    # the intro rides inside the tab, so assert only when the tab exists.
    for {tab, phrase} <- [
          {"files", "Documents kept on this company"},
          {"images", "one can be set as its logo"},
          {"comments", "Notes about the company as a whole"}
        ] do
      {:ok, view, html} = live(conn, base <> "?tab=#{tab}")

      if :sys.get_state(view.pid).socket.assigns.tab == tab do
        assert html =~ phrase
      end
    end
  end

  test "renders the company's name", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    assert html =~ "Initech"
  end

  test "redirects to the companies list for an unknown uuid", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, "/en/admin/crm/companies/#{Ecto.UUID.generate()}")

    assert to =~ "/admin/crm/companies"
  end

  test "has a chrome breadcrumb back to Companies (the rich in-body header stays, on purpose)",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    assert has_element?(view, "#test-page-section[href='/en/admin/crm/companies']", "Companies")
  end

  test "the show strip is core nav_tabs (border) with prefixed patch hrefs", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

    assert html =~ ~s(role="tablist")
    assert html =~ "tabs-border"
    assert has_element?(view, "a.tab-active", "Overview")

    assert has_element?(
             view,
             ~s{a[href="/en/admin/crm/companies/#{company.uuid}?tab=members"]},
             "Members"
           )
  end

  # The Catalogue tab 500ed on first load because @column_picker_available and
  # @catalogue_column_catalog were only assigned from the picker event
  # handlers, never from handle_params. Catalogue is a soft-dep and is not
  # loaded in this suite, so ?tab=catalogue clamps to Overview and a
  # render-succeeds test would pass *without* the fix. The two assigns are
  # set unconditionally, so reading them off the LiveView process is the
  # lock that survives the clamp.
  test "catalogue picker assigns are present on first handle_params (KeyError regression)",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=catalogue")

    assigns = live_assigns(view)
    assert is_boolean(assigns.column_picker_available)
    assert is_list(assigns.catalogue_column_catalog)
  end

  describe "mirror account status (read-only)" do
    test "a linked company shows the mirror user's display name, linking to their admin page",
         %{conn: conn} do
      user = org_user_fixture(%{"organization_name" => "Globex Corp"})
      {:ok, company} = Companies.create_company(%{"name" => "Initech"})
      {:ok, company} = Companies.connect_user(company, user.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

      assert html =~ "Mirror account"
      assert html =~ "Globex Corp"
      assert html =~ ~s(href="/en/admin/users/view/#{user.uuid}")
    end

    test "an unlinked company shows None", %{conn: conn} do
      {:ok, company} = Companies.create_company(%{"name" => "Initech"})

      {:ok, _view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}")

      assert html =~ "Mirror account"
      assert html =~ "None"
    end
  end
end
