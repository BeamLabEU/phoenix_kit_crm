defmodule PhoenixKitCRM.Web.InteractionEndTimeTest do
  @moduledoc """
  A start and an end (Max, 2026-10-06): the composer's "Ended" field kept
  in step with the length, an end that is not after the start refused,
  the span on the feed row, and the same over the projects API.
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Interactions, ProjectApi}
  alias PhoenixKitCRM.Schemas.Interaction
  alias PhoenixKitCRM.Web.InteractionHelpers

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "ends-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    user
  end

  defp change(view, fields, target) do
    view
    |> element("form[phx-change=composer_change]")
    |> render_change(%{"interaction" => fields, "_target" => ["interaction", target]})
  end

  describe "the helpers" do
    test "ended_at is the start plus the length, nil without one" do
      i = %Interaction{occurred_at: ~U[2026-10-04 11:03:00Z], duration_minutes: 180}
      assert Interaction.ended_at(i) == ~U[2026-10-04 14:03:00Z]
      assert Interaction.ended_at(%{i | duration_minutes: nil}) == nil
    end

    test "format_span: the end's time alone on the same local day, both in full across days" do
      from = ~U[2026-10-04 11:03:00Z]

      assert InteractionHelpers.format_span(from, ~U[2026-10-04 14:03:00Z], "+3") ==
               "2026-10-04 14:03 – 17:03"

      # 23:30 → 00:30 local crosses midnight
      assert InteractionHelpers.format_span(
               ~U[2026-10-04 20:30:00Z],
               ~U[2026-10-04 21:30:00Z],
               "+3"
             ) ==
               "2026-10-04 23:30 – 2026-10-05 00:30"

      assert InteractionHelpers.format_span(from, nil, "+3") == "2026-10-04 14:03"
      assert InteractionHelpers.format_span(from, from, "+3") == "2026-10-04 14:03"
    end
  end

  describe "the composer on a company page" do
    setup %{conn: conn} do
      {:ok, company} = Companies.create_company(%{"name" => "Initech"})
      u = user()
      conn = put_test_scope(conn, fake_scope(user_uuid: u.uuid, user_timezone: "Europe/Tallinn"))

      {:ok, view, html} =
        live_composer(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

      {:ok, view: view, html: html, company: company}
    end

    test "an end after the start is saved as the length; the row shows the span", %{
      view: view,
      html: html,
      company: company
    } do
      assert html =~ ~s(name="interaction[ended_at]")

      change(
        view,
        %{
          "subject" => "Site visit",
          "occurred_at" => "2026-10-04T14:03",
          "ended_at" => "2026-10-04T17:03"
        },
        "ended_at"
      )

      view |> element("button[phx-click=save_interaction]") |> render_click()
      # the drawer closes and the feed reloads off the save's message
      html = render(view)

      assert [i] = Interactions.list_for_company(company.uuid)
      assert i.duration_minutes == 180
      assert i.occurred_at == ~U[2026-10-04 11:03:00Z]
      assert html =~ "2026-10-04 14:03 – 17:03"
    end

    test "an end that is not after the start is said, and nothing is saved", %{
      view: view,
      company: company
    } do
      change(
        view,
        %{
          "subject" => "Backwards",
          "occurred_at" => "2026-10-04T14:03",
          "ended_at" => "2026-10-04T13:00"
        },
        "ended_at"
      )

      html = view |> element("button[phx-click=save_interaction]") |> render_click()
      assert html =~ "The end must be after the start."
      assert Interactions.list_for_company(company.uuid) == []
    end

    test "Set to now on the end: the call ended now, the length follows from the start", %{
      view: view,
      company: company
    } do
      started = DateTime.add(DateTime.utc_now(), -25 * 60, :second)
      local = PhoenixKit.Utils.Date.format_datetime_local(started, "Europe/Tallinn")
      change(view, %{"subject" => "Maria called", "occurred_at" => local}, "occurred_at")

      view |> element("#crm-set-end-now") |> render_click()
      view |> element("button[phx-click=save_interaction]") |> render_click()

      assert [i] = Interactions.list_for_company(company.uuid)
      assert i.duration_minutes in 24..26
    end

    test "Set to now on the end in the same minute as the start is one minute, not a refusal", %{
      view: view,
      company: company
    } do
      local = PhoenixKit.Utils.Date.format_datetime_local(DateTime.utc_now(), "Europe/Tallinn")

      change(view, %{"subject" => "Wrong number", "occurred_at" => local}, "occurred_at")
      view |> element("#crm-set-end-now") |> render_click()
      html = view |> element("button[phx-click=save_interaction]") |> render_click()

      refute html =~ "The end must be after the start."
      assert [i] = Interactions.list_for_company(company.uuid)
      assert i.duration_minutes in 1..2
    end

    test "no end leaves the interaction without a length", %{view: view, company: company} do
      change(view, %{"subject" => "Quick note", "occurred_at" => "2026-10-04T14:03"}, "subject")
      view |> element("button[phx-click=save_interaction]") |> render_click()

      assert [i] = Interactions.list_for_company(company.uuid)
      assert is_nil(i.duration_minutes)
    end
  end

  describe "on a project's Client tab" do
    @project "0199a0e0-0000-7000-8000-0000000000fe"

    setup %{conn: conn} do
      {:ok, company} = Companies.create_company(%{"name" => "Hooli"})
      u = user()
      conn = put_test_scope(conn, fake_scope(user_uuid: u.uuid, user_timezone: "Europe/Tallinn"))

      {:ok, view, _html} =
        live_isolated(conn, PhoenixKitCRM.Web.ProjectClientLive,
          session: %{
            "project_uuid" => @project,
            "config" => %{"company_uuid" => company.uuid},
            "can_write" => true,
            "current_user_uuid" => u.uuid,
            "locale" => "en"
          }
        )

      {:ok, view: view, feed: "#crm-project-interactions-#{@project}"}
    end

    defp composer(view, _feed) do
      render_click(view, "open_composer", %{})
      [_, id] = Regex.run(~r/id="(crm-project-composer-[^"]+-\d+)"/, render(view))
      "#" <> id
    end

    test "the length and the end follow each other", %{view: view, feed: feed} do
      composer = composer(view, feed)

      view
      |> with_target(composer)
      |> render_change("composer_change", %{
        "interaction" => %{"occurred_at" => "2026-10-04T14:03", "duration_minutes" => "90"},
        "_target" => ["interaction", "duration_minutes"]
      })

      assert render(view) =~ ~s(value="2026-10-04T15:33")

      view
      |> with_target(composer)
      |> render_change("composer_change", %{
        "interaction" => %{
          "occurred_at" => "2026-10-04T14:03",
          "duration_minutes" => "90",
          "ended_at" => "2026-10-04T17:03"
        },
        "_target" => ["interaction", "ended_at"]
      })

      html = render(view)
      assert html =~ ~s(name="interaction[duration_minutes]")
      assert html =~ ~r/id="crm-duration"[^>]*value="180"|value="180"[^>]*id="crm-duration"/
    end

    test "a planned meeting takes an optional end, never one before its start", %{
      view: view,
      feed: feed
    } do
      # "Plan ahead" opens the same composer, as a plan (V9)
      view |> with_target(feed) |> render_click("start_planning", %{})
      html = render(view)
      assert html =~ "Ends (optional)"
      [_, id] = Regex.run(~r/id="(crm-project-composer-[^"]+-\d+)"/, html)

      view
      |> with_target("#" <> id)
      |> render_change("composer_change", %{
        "interaction" => %{
          "subject" => "Workshop",
          "occurred_at" => "2030-01-10T10:00",
          "ended_at" => "2030-01-10T09:00"
        },
        "_target" => ["interaction", "ended_at"]
      })

      view |> with_target("#" <> id) |> render_click("save_interaction", %{})
      assert render(view) =~ "The end must be after the start."
      assert Interactions.list_for_project(@project) == []
    end
  end

  describe "over the projects API" do
    setup do
      {:ok, company} = Companies.create_company(%{"name" => "Acme"})
      project_uuid = Ecto.UUID.generate()

      {:ok, i} =
        Interactions.create_interaction(
          %{
            "company_uuid" => company.uuid,
            "interaction_type" => "meeting",
            "subject" => "Kickoff",
            "occurred_at" => ~U[2026-10-04 11:03:00Z],
            "project_uuid" => project_uuid
          },
          []
        )

      ctx = %{project: %{uuid: project_uuid}, user_uuid: nil, key: nil, actor: nil}
      {:ok, ctx: ctx, interaction: i}
    end

    test "ended_at becomes the length and is answered back", %{ctx: ctx, interaction: i} do
      assert ProjectApi.to_json(i).ended_at == nil

      assert {:ok, %{interaction: json}} =
               ProjectApi.update(ctx, i.uuid, %{"ended_at" => "2026-10-04T17:03:00+03:00"})

      assert json.duration_minutes == 180
      assert json.ended_at == ~U[2026-10-04 14:03:00Z]

      # with a new start in the same call, the end is measured from that one
      assert {:ok, %{interaction: json}} =
               ProjectApi.update(ctx, i.uuid, %{
                 "occurred_at" => "2026-10-04T12:03:00Z",
                 "ended_at" => "2026-10-04T12:33:00Z"
               })

      assert json.duration_minutes == 30
    end

    test "an end not after the start, one that disagrees with the length, or junk is a 422", %{
      ctx: ctx,
      interaction: i
    } do
      for bad <- [
            %{"ended_at" => "2026-10-04T11:03:00Z"},
            %{"ended_at" => "2026-10-04T10:00:00Z"},
            %{"ended_at" => "soon"},
            %{"ended_at" => 5},
            %{"ended_at" => "2026-10-04T12:03:00Z", "duration_minutes" => 45}
          ] do
        assert {:error, {422, "validation_failed", _, details}} =
                 ProjectApi.update(ctx, i.uuid, bad)

        assert Map.has_key?(details, "ended_at")
      end

      assert is_nil(Interactions.get_interaction(i.uuid).duration_minutes)

      # agreeing with the length is fine
      assert {:ok, _} =
               ProjectApi.update(ctx, i.uuid, %{
                 "ended_at" => "2026-10-04T12:03:00Z",
                 "duration_minutes" => 60
               })
    end
  end
end
