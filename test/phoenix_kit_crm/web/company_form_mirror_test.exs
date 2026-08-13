defmodule PhoenixKitCRM.Web.CompanyFormMirrorTest do
  @moduledoc """
  LiveView integration tests for the mirror panel/picker/conflict flow
  wired into `CompanyFormLive` (Task G). Every fixture is a REAL
  persisted row — see `CompaniesMirrorTest`'s moduledoc for why that
  matters in this codebase.
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, _} = Settings.update_boolean_setting("enable_organization_accounts", true)
    {:ok, conn: put_test_scope(conn, scope), scope: scope}
  end

  defp unique, do: System.unique_integer([:positive])

  defp org_user_fixture(attrs \\ %{}) do
    base = %{
      "email" => "org-#{unique()}@example.test",
      "password" => "Sup3rSecret!24",
      "account_type" => "organization",
      "organization_name" => "Acme"
    }

    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
  end

  defp company_fixture(attrs \\ %{}) do
    {:ok, company} = Companies.create_company(Map.merge(%{"name" => "Acme"}, attrs))
    company
  end

  defp edit(conn, company), do: live(conn, "/en/admin/crm/companies/#{company.uuid}/edit")

  describe "mirror_create" do
    test "creates a mirror user and shows the linked state", %{conn: conn} do
      company =
        company_fixture(%{"name" => "Acme", "email" => "acme-mirror-#{unique()}@example.test"})

      {:ok, view, _html} = edit(conn, company)

      html = render_click(view, "mirror_create")

      assert html =~ "Acme"
      updated = Companies.get_company(company.uuid)
      assert updated.user_uuid != nil
      assert Auth.get_user(updated.user_uuid).account_type == "organization"
    end

    test "is rejected server-side when org accounts are disabled, even if forged", %{conn: conn} do
      # Panel already hides the button in this state (covered by the
      # component's own render tests) — this proves the handler itself
      # doesn't trust the client.
      Settings.update_boolean_setting("enable_organization_accounts", false)
      company = company_fixture()

      {:ok, view, _html} = edit(conn, company)

      render_click(view, "mirror_create")

      assert Companies.get_company(company.uuid).user_uuid == nil
    end
  end

  describe "mirror_open_picker" do
    test "lists unlinked org-users only — a linked one is excluded", %{conn: conn} do
      linked_user = org_user_fixture(%{"organization_name" => "Linked Co #{unique()}"})
      linked_company = company_fixture(%{"name" => "Linked Co"})
      {:ok, _} = Companies.connect_user(linked_company, linked_user.uuid)

      unlinked_name = "Unlinked Co #{unique()}"
      _unlinked_user = org_user_fixture(%{"organization_name" => unlinked_name})

      company = company_fixture(%{"name" => "Target Co"})
      {:ok, view, _html} = edit(conn, company)

      html = render_click(view, "mirror_open_picker")

      assert html =~ unlinked_name
      refute html =~ linked_user.organization_name
    end
  end

  describe "mirror_link — no conflict" do
    test "links directly and fills the user's BLANK organization_name from the company",
         %{conn: conn} do
      user = org_user_fixture(%{"organization_name" => "Placeholder"})
      {:ok, user} = Auth.update_user_profile(user, %{organization_name: nil})

      # Same email on both sides so only organization_name is in play —
      # organization_name can't be blanked at registration (required for
      # account_type: "organization"), so this simulates it post-hoc the
      # same way an org account with an incomplete profile would look.
      company =
        company_fixture(%{"name" => "Acme Corp #{unique()}", "email" => user.email})

      {:ok, view, _html} = edit(conn, company)

      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      assert Companies.get_company(company.uuid).user_uuid == user.uuid
      updated_user = Auth.get_user(user.uuid)
      assert updated_user.organization_name == company.name
      assert updated_user.email == user.email
    end

    test "links directly without touching a field that already matches", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})
      user = org_user_fixture(%{"organization_name" => "Acme", "email" => shared_email})

      {:ok, view, _html} = edit(conn, company)

      html = render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      refute html =~ "Resolve differences"
      assert Companies.get_company(company.uuid).user_uuid == user.uuid
    end
  end

  describe "mirror_link — conflict" do
    test "a diverging org name opens the conflict modal WITHOUT writing anything", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})

      {:ok, view, _html} = edit(conn, company)

      html = render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      assert html =~ "Resolve differences"
      assert html =~ "Acme GmbH"
      refute Companies.get_company(company.uuid).user_uuid
      refute Auth.get_user(user.uuid).organization_name == "Acme"
    end

    test "resolving keep_crm writes the company's name onto the user", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})

      {:ok, view, _html} = edit(conn, company)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_crm"}})

      assert Auth.get_user(user.uuid).organization_name == "Acme"
      assert Companies.get_company(company.uuid).name == "Acme"
      assert Companies.get_company(company.uuid).user_uuid == user.uuid
    end

    test "resolving keep_user writes the user's org name onto the company", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})

      {:ok, view, _html} = edit(conn, company)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      render_submit(view, "mirror_resolve", %{"choices" => %{"name" => "keep_user"}})

      assert Companies.get_company(company.uuid).name == "Acme GmbH"
      assert Auth.get_user(user.uuid).organization_name == "Acme GmbH"
      assert Companies.get_company(company.uuid).user_uuid == user.uuid
    end

    test "cancel writes nothing to either side", %{conn: conn} do
      shared_email = "shared-#{unique()}@example.test"
      company = company_fixture(%{"name" => "Acme", "email" => shared_email})
      user = org_user_fixture(%{"organization_name" => "Acme GmbH", "email" => shared_email})

      {:ok, view, _html} = edit(conn, company)
      render_submit(view, "mirror_link", %{"user_uuid" => user.uuid})

      render_click(view, "mirror_cancel_conflict")

      refute Companies.get_company(company.uuid).user_uuid
      assert Auth.get_user(user.uuid).organization_name == "Acme GmbH"
      assert Companies.get_company(company.uuid).name == "Acme"
    end
  end

  describe "mirror_unlink" do
    test "clears the link; the user row survives", %{conn: conn} do
      company = company_fixture()
      user = org_user_fixture()
      {:ok, _} = Companies.connect_user(company, user.uuid)

      {:ok, view, _html} = edit(conn, company)

      html = render_click(view, "mirror_unlink")

      refute html =~ "mirror_unlink"
      assert Companies.get_company(company.uuid).user_uuid == nil
      assert Auth.get_user(user.uuid) != nil
    end
  end
end
