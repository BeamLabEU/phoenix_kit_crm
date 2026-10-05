defmodule PhoenixKitCRM.ProjectApiTest do
  @moduledoc """
  The interactions provider for the projects API, driven directly (the
  projects module is not a dependency here, so `create` cannot find the
  project's client company and says so; reads, updates and validation are
  proven on rows made by the context).
  """

  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Companies, Contacts, Interactions, ProjectApi}

  defp ctx(project_uuid) do
    %{
      project: %{uuid: project_uuid},
      key: %{uuid: Ecto.UUID.generate()},
      user_uuid: nil,
      actor: %{kind: "ai_agent", uuid: Ecto.UUID.generate()}
    }
  end

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
          "project_uuid" => project_uuid,
          "duration_minutes" => 120
        },
        [%{raw_name: "Max Don", contact_uuid: nil, staff_person_uuid: nil}]
      )

    {:ok, company: company, project_uuid: project_uuid, interaction: i}
  end

  test "the contract: resource, scopes, action, docs rows under /ext" do
    assert ProjectApi.resource() == "interactions"
    assert ProjectApi.scopes() == %{read: "interactions:read", write: "interactions:write"}
    assert ProjectApi.action() == :log_interaction

    assert Enum.map(ProjectApi.docs(), & &1.path) |> Enum.uniq() == [
             "/ext/interactions",
             "/ext/interactions/{id}"
           ]
  end

  test "list and get are scoped to the project", %{project_uuid: pu, interaction: i} do
    assert {:ok, %{count: 1, interactions: [row]}} = ProjectApi.list(ctx(pu), %{})
    assert row.uuid == i.uuid and row.type == "meeting" and row.duration_minutes == 120
    assert [%{name: "Max Don"}] = row.parties

    assert {:ok, %{interaction: %{subject: "Kickoff"}}} = ProjectApi.get(ctx(pu), i.uuid)

    assert {:error, {404, "not_found", _, nil}} =
             ProjectApi.get(ctx(Ecto.UUID.generate()), i.uuid)
  end

  test "update edits the fields, replaces the parties, links the planned event, and validates",
       %{project_uuid: pu, interaction: i} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Maria"})
    event_uuid = Ecto.UUID.generate()

    {:ok, %{interaction: updated}} =
      ProjectApi.update(ctx(pu), i.uuid, %{
        "subject" => "Meeting with Maria",
        "body" => "Three hours.",
        "occurred_at" => "2026-10-04T14:03:00+03:00",
        "time_zone" => "Europe/Tallinn",
        "duration_minutes" => 180,
        "type" => "meeting",
        "event_uuid" => event_uuid,
        "parties" => [
          %{"name" => "Max Don"},
          %{"name" => "Sasha Don"},
          %{"name" => "Maria", "contact_uuid" => contact.uuid}
        ]
      })

    assert updated.subject == "Meeting with Maria"
    assert updated.occurred_at == ~U[2026-10-04 11:03:00Z]
    assert updated.duration_minutes == 180
    assert updated.event_uuid == event_uuid
    assert Enum.map(updated.parties, & &1.name) == ["Max Don", "Sasha Don", "Maria"]
    assert Enum.at(updated.parties, 2).contact_uuid == contact.uuid

    # Parties untouched when not sent; an explicit null unlinks the event.
    {:ok, %{interaction: again}} =
      ProjectApi.update(ctx(pu), i.uuid, %{"body" => "x", "event_uuid" => nil})

    assert length(again.parties) == 3 and again.event_uuid == nil

    for {attrs, field} <- [
          {%{"type" => "rant"}, "type"},
          {%{"duration_minutes" => 0}, "duration_minutes"},
          {%{"occurred_at" => "yesterday"}, "occurred_at"},
          {%{"occurred_at" => "2030-01-01T00:00:00Z"}, "occurred_at"},
          {%{"parties" => [%{"name" => ""}]}, "parties[0].name"},
          {%{"parties" => [%{"name" => "x", "contact_uuid" => Ecto.UUID.generate()}]},
           "parties[0].contact_uuid"},
          {%{
             "parties" => [
               %{
                 "name" => "x",
                 "contact_uuid" => Ecto.UUID.generate(),
                 "staff_person_uuid" => Ecto.UUID.generate()
               }
             ]
           }, "parties[0]"},
          # Types that once raised (`to_string/1` on a map) or slipped through
          {%{"parties" => [%{"name" => %{"first" => "x"}}]}, "parties[0].name"},
          {%{"parties" => [%{"name" => "x", "contact_uuid" => 5}]}, "parties[0].contact_uuid"},
          {%{"parties" => [%{"name" => "x", "staff_person_uuid" => "nope"}]},
           "parties[0].staff_person_uuid"},
          {%{"event_uuid" => String.duplicate("x", 5000)}, "event_uuid"},
          {%{"event_uuid" => 7}, "event_uuid"},
          {%{"subject" => "bad" <> <<0>>}, "subject"},
          {%{"body" => "bad" <> <<0>>}, "body"},
          {%{"time_zone" => "bad" <> <<0>>}, "time_zone"},
          {%{"parties" => [%{"name" => "bad" <> <<0>>}]}, "parties[0].name"},
          {%{"parties" => [%{"name" => "   "}]}, "parties[0].name"}
        ] do
      assert {:error, {422, "validation_failed", _, %{^field => [_]}}} =
               ProjectApi.update(ctx(pu), i.uuid, attrs)
    end
  end

  test "trashed anchors are excluded from project lists, gets and updates", %{
    company: company,
    project_uuid: project_uuid,
    interaction: company_row
  } do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Project contact"})

    {:ok, contact_row} =
      Interactions.create_interaction(%{
        "contact_uuid" => contact.uuid,
        "project_uuid" => project_uuid,
        "subject" => "Contact meeting"
      })

    assert length(Interactions.list_for_project(project_uuid)) == 2
    {:ok, _} = Companies.trash_company(company)
    assert [%{uuid: uuid}] = Interactions.list_for_project(project_uuid, limit: 1)
    assert uuid == contact_row.uuid

    assert {:error, {404, "not_found", _, _}} =
             ProjectApi.get(ctx(project_uuid), company_row.uuid)

    assert {:error, {404, "not_found", _, _}} =
             ProjectApi.update(ctx(project_uuid), company_row.uuid, %{"body" => "hidden"})

    assert Interactions.get_interaction(company_row.uuid).body == nil

    {:ok, _} = Contacts.trash_contact(contact)
    assert {:ok, %{count: 0}} = ProjectApi.list(ctx(project_uuid), %{})

    assert {:error, {404, "not_found", _, _}} =
             ProjectApi.get(ctx(project_uuid), contact_row.uuid)

    # Soft delete hides the feed, retaining the history in storage.
    assert Interactions.get_interaction(contact_row.uuid)
  end

  test "create without a client company on the project is a 409 that says what to do", %{
    project_uuid: pu
  } do
    assert {:error, {409, "no_client", msg, nil}} =
             ProjectApi.create(ctx(pu), %{"subject" => "x"})

    assert msg =~ "Modules & features"
  end
end
