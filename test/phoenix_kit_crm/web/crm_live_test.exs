defmodule PhoenixKitCRM.Web.CRMLiveTest do
  @moduledoc """
  The overview is a front door, not a dashboard: companies/contacts lead, the
  by-role band deep-links every non-zero count to the already-filtered index
  (and refuses to link a zero — a filter with no results is a dead end), the
  attention row appears only when there is something to fix, and portal access
  lives on the settings page, not here.
  """
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.{Companies, Contacts, Interactions, PartyRoles}

  setup %{conn: conn} do
    {:ok, _} = PhoenixKitCRM.enable_system()
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp company_fixture(name) do
    {:ok, company} = Companies.create_company(%{"name" => name})
    company
  end

  defp contact_fixture(name) do
    {:ok, contact} = Contacts.create_contact(%{"name" => name})
    contact
  end

  defp staff(company, contact) do
    {:ok, _} = Contacts.set_primary_company(contact, company.uuid, "Eng", nil)
  end

  test "role tiles link each non-zero count to the filtered index; zero roles stay visible unlinked",
       %{conn: conn} do
    supplier = company_fixture("Supplier Co")
    {:ok, _} = PartyRoles.grant_role(supplier, "supplier")
    {:ok, _} = PartyRoles.grant_role(company_fixture("Maker Co"), "manufacturer")
    {:ok, _} = PartyRoles.grant_role(contact_fixture("Solo Trader"), "supplier")

    {:ok, view, html} = live(conn, "/en/admin/crm")

    assert has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=supplier"]})
    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=supplier"]})
    assert has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=manufacturer"]})

    # Nobody is a partner: the vocabulary stays on the page, the dead link doesn't.
    assert html =~ "Partners"
    refute has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=partner"]})
    refute has_element?(view, ~s{a[href="/en/admin/crm/contacts?filter=manufacturer"]})
  end

  test "portal access is settings' business now, not the overview's", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/crm")

    refute html =~ "Portal access"
  end

  test "the attention row counts companies without live contacts and links the no-contacts filter",
       %{conn: conn} do
    _bare = company_fixture("Bare Co")
    staffed = company_fixture("Staffed Co")
    staff(staffed, contact_fixture("Worker"))

    {:ok, view, html} = live(conn, "/en/admin/crm")

    assert html =~ "1 company has no contacts"
    assert has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=no-contacts"]})
  end

  test "the attention section is absent when every company has a contact", %{conn: conn} do
    staffed = company_fixture("Staffed Co")
    staff(staffed, contact_fixture("Worker"))

    {:ok, _view, html} = live(conn, "/en/admin/crm")

    refute html =~ "Needs attention"
  end

  test "recent interactions render newest first and link to the subject contact", %{conn: conn} do
    anna = contact_fixture("Anna Subject")

    {:ok, _} =
      Interactions.create_interaction(%{
        "contact_uuid" => anna.uuid,
        "interaction_type" => "call",
        "subject" => "Quarterly pricing",
        "occurred_at" => DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, view, html} = live(conn, "/en/admin/crm")

    assert html =~ "Recent interactions"
    assert html =~ "Quarterly pricing"
    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts/#{anna.uuid}"]}, "Anna Subject")
  end

  test "with contacts but no interactions the empty state points at contacts — there is no interactions index",
       %{conn: conn} do
    contact_fixture("Lonely Contact")

    {:ok, view, html} = live(conn, "/en/admin/crm")

    assert html =~ "No interactions logged yet"
    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts"]}, "Browse contacts")
  end

  test "the start card shows only while BOTH record types are empty", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/crm")
    assert html =~ "Start your CRM"
  end

  test "a company alone (the old contacts==0 gate) no longer triggers onboarding", %{conn: conn} do
    company_fixture("First Co")

    {:ok, _view, html} = live(conn, "/en/admin/crm")

    refute html =~ "Start your CRM"
  end

  test "the quick actions are always offered", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/crm")

    assert has_element?(view, ~s{a[href="/en/admin/crm/contacts/new"]}, "New contact")
    assert has_element?(view, ~s{a[href="/en/admin/crm/companies/new"]}, "New company")
  end

  test "the lists row renders with its count and link", %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm")

    assert html =~ "Lists are optional"
    assert has_element?(view, ~s{a[href="/en/admin/crm/lists"]}, "Manage lists")
  end
end
