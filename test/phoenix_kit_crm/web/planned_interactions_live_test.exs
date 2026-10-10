defmodule PhoenixKitCRM.Web.PlannedInteractionsLiveTest do
  @moduledoc """
  V9 on the CRM's own pages: planning without a project. "Plan ahead" on a
  company page, the Planned card, "Log what happened" and "It was
  cancelled" on the same row, and the two saves that are refused.
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Contacts, Interactions}

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "planner-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    user
  end

  defp change(view, fields) do
    view
    |> element("form[phx-change=composer_change]")
    |> render_change(%{"interaction" => fields})
  end

  defp save(view) do
    view |> element("button[phx-click=save_interaction]") |> render_click()
    render(view)
  end

  setup %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    u = user()
    conn = put_test_scope(conn, fake_scope(user_uuid: u.uuid, user_timezone: "Europe/Tallinn"))
    {:ok, view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")
    {:ok, view: view, html: html, company: company, conn: conn}
  end

  test "the page shows the feed and the two ways in; the composer is not open", %{html: html} do
    assert html =~ "Plan ahead"
    assert html =~ "Log an interaction"
    assert html =~ "Nothing planned."
    refute html =~ ~s(phx-change="composer_change")
  end

  test "Plan ahead saves a plan, with people and a place; it lists under Planned, not in the feed",
       %{view: view, company: company} do
    {:ok, maria} = Contacts.create_contact(%{"name" => "Maria Tamm"})

    view |> element("button[phx-click=start_planning]") |> render_click()
    html = render(view)
    assert html =~ ~r/for="crm-when"[^>]*><span[^>]*>Starts</
    assert html =~ "Ends (optional)"
    assert html =~ "Plan it"
    # a plan has no "Set to now" on its end
    refute html =~ ~s(id="crm-set-end-now")

    view
    |> with_target("div[id^='crm-company-composer-#{company.uuid}-']")
    |> render_hook("stage_party", %{
      "kind" => "contact",
      "uuid" => maria.uuid,
      "label" => "Maria Tamm"
    })

    change(view, %{
      "subject" => "Showroom visit",
      "occurred_at" => "2031-03-04T10:00",
      "ended_at" => "2031-03-04T11:30",
      "location" => "ANDI showroom"
    })

    html = save(view)

    assert [i] = Interactions.list_for_company(company.uuid)
    assert i.status == "planned"
    assert i.interaction_type == "meeting"
    assert i.location == "ANDI showroom"
    assert i.occurred_at == ~U[2031-03-04 08:00:00Z]
    assert i.planned_at == i.occurred_at
    assert [%{raw_name: "Maria Tamm"}] = i.parties

    assert html =~ ~s(id="crm-planned-#{i.uuid}")
    assert html =~ "Showroom visit"
    assert html =~ "ANDI showroom"
    assert html =~ "Maria Tamm"
    refute html =~ ~s(id="crm-interaction-#{i.uuid}")
    refute html =~ "needs an outcome"
    # the drawer closed
    refute html =~ ~s(phx-change="composer_change")
  end

  describe "a plan whose time has passed" do
    setup %{conn: conn, company: company} do
      {:ok, plan} =
        Interactions.create_interaction(%{
          "company_uuid" => company.uuid,
          "interaction_type" => "meeting",
          "subject" => "Site visit",
          "status" => "planned",
          "occurred_at" => ~U[2026-10-04 11:00:00Z]
        })

      {:ok, view, html} = live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")
      {:ok, view: view, html: html, plan: plan}
    end

    test "it waits for an outcome; nothing turns it into a record by itself", %{
      html: html,
      plan: plan
    } do
      assert html =~ "needs an outcome"
      assert Interactions.get_interaction(plan.uuid).status == "planned"
    end

    test "Log what happened records it on the same row and keeps when it was planned for", %{
      view: view,
      company: company,
      plan: plan
    } do
      view |> element("button[phx-click=log_planned]") |> render_click()
      html = render(view)
      assert html =~ "Log what happened"
      assert html =~ ~s(aria-pressed="true" class="btn btn-sm join-item btn-primary")

      # it really started twenty minutes late
      change(view, %{
        "subject" => "Site visit",
        "body" => "Measured the kitchen.",
        "occurred_at" => "2026-10-04T14:20"
      })

      html = save(view)

      assert [i] = Interactions.list_for_company(company.uuid)
      assert i.uuid == plan.uuid
      assert i.status == "happened"
      assert i.body == "Measured the kitchen."
      assert i.occurred_at == ~U[2026-10-04 11:20:00Z]
      assert i.planned_at == ~U[2026-10-04 11:00:00Z]

      assert html =~ ~s(id="crm-interaction-#{i.uuid}")
      assert html =~ "Planned 2026-10-04 14:00"
      assert html =~ "Nothing planned."
    end

    test "It was cancelled keeps the row, struck through, with the time it still cost", %{
      view: view,
      company: company,
      plan: plan
    } do
      view
      |> with_target("#crm-company-interactions-#{company.uuid}")
      |> render_click("cancel_planned", %{"uuid" => plan.uuid})

      html = render(view)
      assert html =~ "It did not take place."

      change(view, %{
        "subject" => "Site visit",
        "body" => "Drove two hours; the client cancelled at the door.",
        "occurred_at" => "2026-10-04T14:00",
        "ended_at" => "2026-10-04T16:00"
      })

      view
      |> element("form[phx-change=composer_change]")
      |> render_change(%{
        "interaction" => %{
          "subject" => "Site visit",
          "body" => "Drove two hours; the client cancelled at the door.",
          "occurred_at" => "2026-10-04T14:00",
          "ended_at" => "2026-10-04T16:00"
        },
        "_target" => ["interaction", "ended_at"]
      })

      html = save(view)

      assert [i] = Interactions.list_for_company(company.uuid)
      assert i.uuid == plan.uuid
      assert i.status == "cancelled"
      assert i.duration_minutes == 120
      assert html =~ "Cancelled"
      assert html =~ "line-through"
    end
  end

  test "a record cannot be of something still to come", %{view: view, company: company} do
    view |> element("button[phx-click=open_composer]") |> render_click()
    render(view)

    change(view, %{"subject" => "Next year", "occurred_at" => "2031-03-04T10:00"})
    html = save(view)

    assert html =~ "That time is still to come."
    assert Interactions.list_for_company(company.uuid) == []
  end
end
