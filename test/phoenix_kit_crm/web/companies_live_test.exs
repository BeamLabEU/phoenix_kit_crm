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
