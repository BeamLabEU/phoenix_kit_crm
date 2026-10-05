defmodule PhoenixKitCRM.Web.ProjectClientEditTest do
  @moduledoc """
  The Client tab's drawer in EDIT mode, mounted for real: the row's saved
  parties stand in for the staged ones, and the viewer (here a free-text
  party spelled like their account) is offered a minutes box — the path
  that once raised `BadBooleanError` from a string on the left of `and`.
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Interactions}
  alias PhoenixKitCRM.Web.ProjectClientLive

  @project "0199a0e0-0000-7000-8000-0000000000ff"

  test "Edit on a row opens the composer with the viewer offered as an attendee", %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "taavi-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24",
        "first_name" => "Taavi",
        "last_name" => "Tester"
      })

    {:ok, company} = Companies.create_company(%{"name" => "Initech"})

    {:ok, call} =
      Interactions.create_interaction(
        %{
          "company_uuid" => company.uuid,
          "interaction_type" => "call",
          "subject" => "Billing call",
          "occurred_at" => DateTime.utc_now(),
          "project_uuid" => @project,
          "duration_minutes" => 30,
          "owner_user_uuid" => user.uuid
        },
        [
          %{raw_name: "Taavi Tester", contact_uuid: nil, staff_person_uuid: nil},
          %{raw_name: "A client", contact_uuid: nil, staff_person_uuid: nil}
        ]
      )

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))

    {:ok, view, _html} =
      live_isolated(conn, ProjectClientLive,
        session: %{
          "project_uuid" => @project,
          "config" => %{"company_uuid" => company.uuid},
          "can_write" => true,
          "current_user_uuid" => user.uuid,
          "locale" => "en"
        }
      )

    assert render(view) =~ "Billing call"

    view
    |> with_target("#crm-project-interactions-#{@project}")
    |> render_click("edit_interaction", %{"uuid" => call.uuid})

    html = render(view)
    assert html =~ "Edit interaction"
    assert html =~ "Saving logs these attendees"
    assert html =~ ~s(name="attendee_minutes[me]")
    # the client is an attendee, not time
    refute html =~ ~s(name="attendee_minutes[text)
    # the saved parties are the chips, the viewer badged
    assert html =~ "Taavi Tester"
    assert html =~ "(you)"
    assert html =~ "A client"

    # Parties can change in an edit: add one, drop one, save.
    composer = "#" <> composer_id(html)

    view |> with_target(composer) |> render_hook("stage_text", %{"name" => "Her colleague"})
    view |> with_target(composer) |> render_hook("remove_party", %{"idx" => "1"})

    view
    |> with_target(composer)
    |> render_change("composer_change", %{
      "interaction" => %{"subject" => "Billing call, two of them"},
      "attendee_minutes" => %{"me" => "0"}
    })

    view |> with_target(composer) |> render_click("save_interaction", %{})

    updated = Interactions.get_interaction(call.uuid)
    assert updated.subject == "Billing call, two of them"
    assert Enum.map(updated.parties, & &1.raw_name) == ["Taavi Tester", "Her colleague"]
  end

  defp composer_id(html) do
    [_, id] = Regex.run(~r/id="(crm-project-composer-[^"]+-\d+)"/, html)
    id
  end
end
