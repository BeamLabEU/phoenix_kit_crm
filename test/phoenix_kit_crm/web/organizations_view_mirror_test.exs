defmodule PhoenixKitCRM.Web.OrganizationsViewMirrorTest do
  @moduledoc """
  LiveView integration tests for the reverse mirror flow on the
  Organizations list view (Task I) — creating/linking a Company FROM an
  organization-user. The USER is master here (`master: :user`), the
  inverse of Tasks G/H where the CRM record is master. Reuses the same
  controlled-choices + fresh-diff-at-resolve pattern, adapted for a list
  view where the conflict modal is SHARED across rows (exactly one
  pending {user_uuid, company_uuid} pair tracked at a time).
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    scope = fake_scope()
    # OrganizationsView.mount/3 gates on BOTH — unlike the Company/Contact
    # form LiveViews, which don't check module-enabled at all.
    {:ok, _} = PhoenixKitCRM.enable_system()
    {:ok, _} = Settings.update_boolean_setting("enable_organization_accounts", true)
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  defp unique, do: System.unique_integer([:positive])

  defp org_user_fixture(attrs \\ %{}) do
    base = %{
      "email" => "org-#{unique()}@example.test",
      "password" => "Sup3rSecret!24",
      "account_type" => "organization",
      "organization_name" => "Acme #{unique()}"
    }

    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
  end

  defp company_fixture(attrs) do
    {:ok, company} = Companies.create_company(Map.merge(%{"name" => "Acme"}, attrs))
    company
  end

  defp view(conn), do: live(conn, "/en/admin/crm/organizations")

  describe "row rendering" do
    test "an unlinked org-user offers Create + Link, a linked one shows the badge and no actions",
         %{conn: conn} do
      unlinked_user = org_user_fixture(%{"organization_name" => "Unlinked Co #{unique()}"})

      linked_user = org_user_fixture(%{"organization_name" => "Linked Co #{unique()}"})
      linked_company = company_fixture(%{"name" => "Linked Co"})
      {:ok, _} = Companies.connect_user(linked_company, linked_user.uuid)

      {:ok, view, html} = view(conn)

      assert html =~ "mirror_create_company"
      assert html =~ "mirror_open_company_picker"
      assert html =~ "Linked"
      assert html =~ linked_company.name

      # Both rows present.
      assert has_element?(view, "*", unlinked_user.organization_name)
      assert has_element?(view, "*", linked_user.organization_name)
    end
  end

  describe "mirror_create_company" do
    test "creates a company from the user's name/email and links it", %{conn: conn} do
      user =
        org_user_fixture(%{
          "organization_name" => "Globex #{unique()}",
          "email" => "globex-#{unique()}@example.test"
        })

      {:ok, view, _html} = view(conn)

      html = render_click(view, "mirror_create_company", %{"user_uuid" => user.uuid})

      assert html =~ user.organization_name

      linked = Companies.get_by_user_uuid(user.uuid)
      assert linked != nil
      assert linked.name == user.organization_name
      assert linked.email == user.email
    end
  end

  describe "mirror_open_company_picker" do
    test "candidates exclude linked and trashed companies", %{conn: conn} do
      user = org_user_fixture()

      unlinked = company_fixture(%{"name" => "Unlinked #{unique()}"})

      other_user = org_user_fixture()
      linked = company_fixture(%{"name" => "Already Linked #{unique()}"})
      {:ok, _} = Companies.connect_user(linked, other_user.uuid)

      trashed = company_fixture(%{"name" => "Trashed #{unique()}"})
      {:ok, _} = Companies.trash_company(trashed)

      {:ok, view, _html} = view(conn)

      html = render_click(view, "mirror_open_company_picker", %{"user_uuid" => user.uuid})

      # Scope to the picker's own <option> tags — `linked.name` legitimately
      # appears elsewhere on the page too (in `other_user`'s own row, which
      # correctly shows its real linked company — that's not a leak).
      picker_options = picker_select_html(html)

      assert picker_options =~ unlinked.name
      refute picker_options =~ linked.name
      refute picker_options =~ trashed.name
    end
  end

  defp picker_select_html(html) do
    [_before, after_marker] =
      String.split(html, ~s(id="mirror-company-picker-select"), parts: 2)

    case String.split(after_marker, "</select>", parts: 2) do
      [select_body, _rest] -> select_body
      [select_body] -> select_body
    end
  end

  describe "mirror_link_company — no conflict" do
    test "links directly when the company name matches, fills a blank company field from the user",
         %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme", "email" => shared_email})
      # Company has a blank email — filled from the user (master here).
      company = company_fixture(%{"name" => "Acme", "email" => nil})

      {:ok, view, _html} = view(conn)

      html =
        render_submit(view, "mirror_link_company", %{
          "user_uuid" => user.uuid,
          "company_uuid" => company.uuid
        })

      refute html =~ "Resolve differences"
      updated = Companies.get_company(company.uuid)
      assert updated.user_uuid == user.uuid
      assert updated.email == shared_email
    end
  end

  describe "mirror_link_company — conflict" do
    test "a diverging company name opens the conflict modal (master :user) WITHOUT writing anything",
         %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      html =
        render_submit(view, "mirror_link_company", %{
          "user_uuid" => user.uuid,
          "company_uuid" => company.uuid
        })

      assert html =~ "Resolve differences"
      # master is :user, so the keep_user (Acme GmbH) radio defaults checked.
      assert html =~ ~r/value="keep_user"[^>]*checked/
      refute html =~ ~r/value="keep_crm"[^>]*checked/
      refute Companies.get_company(company.uuid).user_uuid
    end

    test "resolving keep_user writes the user's name onto the company", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      render_submit(view, "mirror_link_company", %{
        "user_uuid" => user.uuid,
        "company_uuid" => company.uuid
      })

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_user"}})

      updated = Companies.get_company(company.uuid)
      assert updated.name == "Acme GmbH"
      assert updated.user_uuid == user.uuid
    end

    # "Keep CRM" rewrites the USER's organization name; the row renders that
    # straight off @users, which used to keep the old struct until a reload.
    test "resolving keep_crm updates the user's row on screen", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme Ltd", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      render_submit(view, "mirror_link_company", %{
        "user_uuid" => user.uuid,
        "company_uuid" => company.uuid
      })

      html = render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_crm"}})

      assert Auth.get_user(user.uuid).organization_name == "Acme Ltd"
      assert html =~ "Acme Ltd"
      refute html =~ "Acme GmbH"
    end

    test "resolving keep_crm keeps the company's name", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      render_submit(view, "mirror_link_company", %{
        "user_uuid" => user.uuid,
        "company_uuid" => company.uuid
      })

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_crm"}})

      updated = Companies.get_company(company.uuid)
      assert updated.name == "Acme"
      assert updated.user_uuid == user.uuid
    end

    test "cancel writes nothing", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      render_submit(view, "mirror_link_company", %{
        "user_uuid" => user.uuid,
        "company_uuid" => company.uuid
      })

      render_click(view, "mirror_cancel_conflict")

      refute Companies.get_company(company.uuid).user_uuid
      assert Companies.get_company(company.uuid).name == "Acme"
    end

    test "a selection made in the modal survives an intervening unrelated re-render", %{
      conn: conn
    } do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      render_submit(view, "mirror_link_company", %{
        "user_uuid" => user.uuid,
        "company_uuid" => company.uuid
      })

      html = render_change(view, "mirror_choice_changed", %{"choices" => %{"name" => "keep_crm"}})
      assert html =~ ~r/value="keep_crm"[^>]*checked/

      # Unrelated re-render: this view's own existing "show_column_modal"
      # handler (from ColumnManagement), untouched by any mirror state.
      html = render_click(view, "show_column_modal")

      assert html =~ ~r/value="keep_crm"[^>]*checked/
      refute html =~ ~r/value="keep_user"[^>]*checked/
    end

    test "a crafted mirror_choice_changed with a bogus field key is ignored, not crashed", %{
      conn: conn
    } do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      render_submit(view, "mirror_link_company", %{
        "user_uuid" => user.uuid,
        "company_uuid" => company.uuid
      })

      html =
        render_change(view, "mirror_choice_changed", %{
          "choices" => %{"bogus_field" => "keep_crm", "name" => "keep_crm"}
        })

      assert Process.alive?(view.pid)
      assert html =~ ~r/value="keep_crm"[^>]*checked/
    end

    test "mirror_resolve recomputes diff fresh — a field no longer diverging at submit time is dropped",
         %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = view(conn)

      render_submit(view, "mirror_link_company", %{
        "user_uuid" => user.uuid,
        "company_uuid" => company.uuid
      })

      # Out-of-band change: the company's name is updated to match the
      # user's name WITHOUT going through this LiveView.
      {:ok, _} = Companies.update_company(company, %{"name" => "Acme GmbH"})

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_crm"}})

      # "keep_crm" writes the CRM value onto the *user* side (organization_name),
      # never onto the company itself. A naive implementation trusting the
      # stale pre-fetch would still see "Acme" vs "Acme GmbH" as diverging
      # and overwrite the user's already-correct "Acme GmbH" back to the
      # stale "Acme" — assert it didn't.
      updated_user = Auth.get_user(user.uuid)
      assert updated_user.organization_name == "Acme GmbH"

      # The company itself was never a write target for this choice either
      # way — confirm the out-of-band value survives untouched.
      updated_company = Companies.get_company(company.uuid)
      assert updated_company.name == "Acme GmbH"
    end
  end
end
