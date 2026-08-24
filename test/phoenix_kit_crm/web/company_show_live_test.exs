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

  test "the Interactions tab says interactions are logged on the contact — a sentence, no per-member links",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    anna = member_fixture(company, "Anna Member")

    {:ok, _view, html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    assert html =~ "logged on the contact&#39;s own page"
    refute html =~ ~s(href="/en/admin/crm/contacts/#{anna.uuid}?tab=interactions")
    refute html =~ "no contacts yet"
  end

  test "the Interactions tab points to the Members tab when the company has no contacts",
       %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, _view, html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    assert html =~ "no contacts yet"
    assert html =~ "Members tab first"
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
