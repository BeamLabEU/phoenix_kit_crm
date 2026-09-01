defmodule PhoenixKitCRM.Web.CompaniesLiveTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKitCRM.Companies

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "lists active companies", %{conn: conn} do
    {:ok, _company} = Companies.create_company(%{"name" => "Globex Corporation"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies")

    assert html =~ "Globex Corporation"
  end

  test "the page title lives in the chrome assign, not a duplicate in-body heading",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/crm/companies")

    assert html =~ ~s(id="test-page-title")
    refute html =~ "<h1"
    refute has_element?(view, "h1")
  end

  test "the filter strip is core nav_tabs (border) with prefixed patch hrefs", %{conn: conn} do
    {:ok, supplier_co} = Companies.create_company(%{"name" => "Supplier Co"})
    {:ok, _} = PhoenixKitCRM.PartyRoles.grant_role(supplier_co, "supplier")
    {:ok, _} = Companies.create_company(%{"name" => "Plain Co"})

    {:ok, view, html} = live(conn, "/en/admin/crm/companies")

    assert html =~ ~s(role="tablist")
    assert html =~ "tabs-border"
    # The default tab is honestly "All" — the old "Active" label promised a
    # status dichotomy the strip didn't offer — and every label has its count.
    assert has_element?(view, "a.tab-active", "All (2)")

    assert has_element?(
             view,
             ~s{a[href="/en/admin/crm/companies?filter=supplier"]},
             "Suppliers (1)"
           )

    # Filters with nothing behind them aren't offered.
    refute has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=customer"]})
    refute has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=partner"]})
    refute has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=trashed"]})
    # Everything is active, so the Active/Inactive pair would be noise.
    refute has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=active"]})
  end

  test "the Active/Inactive pair appears once an inactive company exists, and both scope by status",
       %{conn: conn} do
    {:ok, _} = Companies.create_company(%{"name" => "Awake Co"})
    {:ok, _} = Companies.create_company(%{"name" => "Dormant Co", "status" => "inactive"})

    {:ok, view, html} = live(conn, "/en/admin/crm/companies")

    # The default view is All: everything not trashed, inactive included —
    # exactly the scope the old "Active" tab silently had.
    assert html =~ "Awake Co"
    assert html =~ "Dormant Co"
    assert has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=active"]}, "Active (1)")

    assert has_element?(
             view,
             ~s{a[href="/en/admin/crm/companies?filter=inactive"]},
             "Inactive (1)"
           )

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies?filter=inactive")
    assert html =~ "Dormant Co"
    refute html =~ "Awake Co"
    assert html =~ "1 inactive company"

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies?filter=active")
    assert html =~ "Awake Co"
    refute html =~ "Dormant Co"
  end

  test "the toolbar count names the filter, not a bare company count", %{conn: conn} do
    {:ok, supplier_co} = Companies.create_company(%{"name" => "Sole Vendor"})
    {:ok, _} = PhoenixKitCRM.PartyRoles.grant_role(supplier_co, "supplier")
    {:ok, _} = Companies.create_company(%{"name" => "Other Firm"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies?filter=supplier")
    assert html =~ "1 supplier"
    refute html =~ "1 company"
  end

  test "the no-contacts filter lists only companies without live contacts and names itself in the strip",
       %{conn: conn} do
    {:ok, bare} = Companies.create_company(%{"name" => "Bare Co"})
    {:ok, staffed} = Companies.create_company(%{"name" => "Staffed Co"})
    {:ok, worker} = PhoenixKitCRM.Contacts.create_contact(%{"name" => "Worker"})
    {:ok, _} = PhoenixKitCRM.Contacts.set_primary_company(worker, staffed.uuid, "Eng", nil)

    {:ok, view, html} = live(conn, "/en/admin/crm/companies?filter=no-contacts")

    assert html =~ "Bare Co"
    refute html =~ "Staffed Co"
    # Not advertised in the strip — the overview's attention row is the way in —
    # but the current view names itself while you're on it.
    assert has_element?(view, "a.tab-active", "No contacts")
    assert bare.uuid != staffed.uuid

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies")
    refute has_element?(view, "a", "No contacts")
  end

  test "an empty filter result says the filter matched nothing, not that no companies exist",
       %{conn: conn} do
    {:ok, staffed} = Companies.create_company(%{"name" => "Fully Staffed Co"})
    {:ok, worker} = PhoenixKitCRM.Contacts.create_contact(%{"name" => "Worker"})
    {:ok, _} = PhoenixKitCRM.Contacts.set_primary_company(worker, staffed.uuid, "Eng", nil)

    {:ok, _view, html} = live(conn, "/en/admin/crm/companies?filter=no-contacts")

    assert html =~ "No companies match this filter."
    refute html =~ "No companies yet."
  end

  test "the Trashed tab appears once a company is in the trash", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "To Be Trashed"})
    {:ok, _} = Companies.trash_company(company)

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies")

    assert has_element?(view, ~s{a[href="/en/admin/crm/companies?filter=trashed"]})
  end

  test "New company is reachable in the table's toolbar, not a page-level header",
       %{conn: conn} do
    {:ok, _company} = Companies.create_company(%{"name" => "Globex Corporation"})

    {:ok, view, _html} = live(conn, "/en/admin/crm/companies")

    assert has_element?(view, ~s{a[href="/en/admin/crm/companies/new"]}, "New company")
  end

  describe "pagination" do
    test "more than a page of companies splits across pages, page 2 reachable via ?page=2",
         %{conn: conn} do
      for n <- 1..26 do
        {:ok, _} =
          Companies.create_company(%{"name" => "Company #{String.pad_leading("#{n}", 2, "0")}"})
      end

      {:ok, view, html} = live(conn, "/en/admin/crm/companies")
      assert html =~ "Company 01"
      assert html =~ "Company 25"
      refute html =~ "Company 26"
      assert html =~ "26 companies"
      assert has_element?(view, "a", "2")

      {:ok, _view2, html2} = live(conn, "/en/admin/crm/companies?page=2")
      refute html2 =~ "Company 01"
      assert html2 =~ "Company 26"
    end

    # Regression: String.to_integer/1 raises on anything non-numeric, so a
    # fat-fingered bookmark or a crawler hitting ?page=abc used to crash
    # this LiveView outright — mount must survive and fall back to page 1.
    test "a non-numeric ?page= param doesn't crash the mount, falls back to page 1",
         %{conn: conn} do
      {:ok, _} = Companies.create_company(%{"name" => "Solo Company"})

      for bad <- ["abc", "", "1.5", "1abc", "-1e5", "0"] do
        assert {:ok, _view, html} = live(conn, "/en/admin/crm/companies?page=#{bad}")
        assert html =~ "Solo Company"
      end
    end

    test "a page past the last one clamps down to the real last page instead of showing empty",
         %{conn: conn} do
      {:ok, _} = Companies.create_company(%{"name" => "Solo Company"})

      {:ok, _view, html} = live(conn, "/en/admin/crm/companies?page=999")

      assert html =~ "Solo Company"
      refute html =~ "No companies yet."
      refute html =~ "No companies on this page."
    end

    # With more than one real page, the clamp must land on the ACTUAL last
    # page (2, holding "Company 26"), not just fall back to page 1 — this is
    # also the exact shape of the reported OOM crash
    # (GET /admin/crm/contacts?page=9999999999): a huge, out-of-range page
    # number against a small total_pages must resolve to real data, not an
    # empty page or a runaway range.
    test "a huge page number clamps to the real last page, not page 1", %{conn: conn} do
      for n <- 1..26 do
        {:ok, _} =
          Companies.create_company(%{"name" => "Company #{String.pad_leading("#{n}", 2, "0")}"})
      end

      {:ok, _view, html} = live(conn, "/en/admin/crm/companies?page=9999999999")

      refute html =~ "Company 01"
      assert html =~ "Company 26"
    end
  end

  describe "search" do
    test "narrows the table by name or email", %{conn: conn} do
      {:ok, _} =
        Companies.create_company(%{"name" => "Alpha Wonders", "email" => "a@example.com"})

      {:ok, _} =
        Companies.create_company(%{"name" => "Beta Corp", "email" => "wonder@beta.example"})

      {:ok, _} = Companies.create_company(%{"name" => "Gamma Inc"})

      {:ok, view, html} = live(conn, "/en/admin/crm/companies")
      assert html =~ "Alpha Wonders"
      assert html =~ "Beta Corp"
      assert html =~ "Gamma Inc"

      html =
        view
        |> element("form[phx-submit='search'] input[name='search']")
        |> render_change(%{"search" => "wonder"})

      assert html =~ "Alpha Wonders"
      assert html =~ "Beta Corp"
      refute html =~ "Gamma Inc"
      assert html =~ "2 companies"
    end
  end
end
