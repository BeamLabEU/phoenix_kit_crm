defmodule PhoenixKitCRM.Web.RecentPartiesTest do
  @moduledoc """
  Recent people beside "Add me" (Max, 2026-10-07): the composer offers the
  people this page's interactions involved lately as one-click chips.
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Interactions}

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "recent-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    user
  end

  defp logged(company, subject, at, names) do
    {:ok, i} =
      Interactions.create_interaction(
        %{
          "interaction_type" => "meeting",
          "subject" => subject,
          "company_uuid" => company.uuid,
          "occurred_at" => at
        },
        Enum.map(names, &%{raw_name: &1})
      )

    i
  end

  setup %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Initech"})
    conn = put_test_scope(conn, fake_scope(user_uuid: user().uuid))
    {:ok, conn: conn, company: company}
  end

  defp open(conn, company),
    do: live_composer(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

  test "nothing is offered on a page with no interactions", %{conn: conn, company: company} do
    {:ok, _view, html} = open(conn, company)
    refute html =~ "stage_recent"
  end

  test "each person once, newest first; a click stages them and the chip leaves", %{
    conn: conn,
    company: company
  } do
    logged(company, "Older", ~U[2026-10-01 10:00:00Z], ["Maria Tamm", "Old Hand"])
    logged(company, "Newer", ~U[2026-10-05 10:00:00Z], ["Maria Tamm", "Peeter Kask"])

    {:ok, view, html} = open(conn, company)

    chips =
      ~r/phx-click="stage_recent"[^>]*title="Add ([^"]+)"/
      |> Regex.scan(html)
      |> Enum.map(&List.last/1)

    assert Enum.sort(chips) == ["Maria Tamm", "Old Hand", "Peeter Kask"]
    assert List.last(chips) == "Old Hand"

    html =
      view |> element(~s(button[phx-click=stage_recent][title="Add Old Hand"])) |> render_click()

    refute html =~ ~s(title="Add Old Hand")
    assert html =~ ~s(title="Add Maria Tamm")
    assert html =~ ~s(phx-click="remove_party")

    # an index past the row is ignored
    assert render_hook_safe(view, 99) =~ ~s(title="Add Maria Tamm")
  end

  defp render_hook_safe(view, idx) do
    view
    |> element(~s(button[phx-click=stage_recent][title="Add Maria Tamm"]))
    |> render_click(%{"idx" => idx})
  end

  test "six at most", %{conn: conn, company: company} do
    logged(company, "Crowd", ~U[2026-10-05 10:00:00Z], for(n <- 1..9, do: "Person #{n}"))

    {:ok, _view, html} = open(conn, company)
    assert length(Regex.scan(~r/phx-click="stage_recent"/, html)) == 6
  end
end
