defmodule PhoenixKitCRM.PlannedInteractionsTest do
  @moduledoc """
  V9: an interaction has a status — planned, happened, cancelled — and is
  the same row from plan to record. The schema's rules, the lists that must
  not take a plan for contact that happened, the activity trail that keeps
  the row's history, who is told, and the same over the projects API.
  """

  use PhoenixKitCRM.DataCase, async: true

  import PhoenixKitCRM.ActivityLogAssertions

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Contacts, InteractionNotifier, Interactions, ProjectApi}
  alias PhoenixKitCRM.Schemas.Interaction
  alias PhoenixKitCRM.Test.Repo

  @tomorrow DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), 86_400)
  @yesterday DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -86_400)

  setup do
    {:ok, company} = Companies.create_company(%{"name" => "Acme"})
    {:ok, company: company}
  end

  defp plan(company, attrs \\ %{}, parties \\ []) do
    {:ok, i} =
      Interactions.create_interaction(
        Map.merge(
          %{
            "company_uuid" => company.uuid,
            "interaction_type" => "meeting",
            "subject" => "Site visit",
            "status" => "planned",
            "occurred_at" => @tomorrow
          },
          attrs
        ),
        parties
      )

    i
  end

  defp linked_contact(name) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "plan-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    {:ok, contact} = Contacts.create_contact(%{"name" => name})
    {:ok, contact, _} = Contacts.connect_user(contact, user.email)
    {contact, user}
  end

  describe "the row" do
    test "a row is happened unless said otherwise; a bad status is refused", %{company: company} do
      {:ok, i} = Interactions.create_interaction(%{"company_uuid" => company.uuid})
      assert i.status == "happened"
      assert i.planned_at == nil

      assert {:error, cs} =
               Interactions.create_interaction(%{
                 "company_uuid" => company.uuid,
                 "status" => "maybe"
               })

      assert Keyword.has_key?(cs.errors, :status)
    end

    test "planned_at follows the start while it is a plan, and stays once it is logged", %{
      company: company
    } do
      i = plan(company, %{"location" => "  ANDI office  "})
      assert i.status == "planned"
      assert i.planned_at == @tomorrow
      assert i.location == "ANDI office"

      moved = DateTime.add(@tomorrow, 3600)
      {:ok, i} = Interactions.update_interaction(i, %{"occurred_at" => moved})
      assert i.planned_at == moved

      # logged: it really started twenty minutes late
      actual = DateTime.add(moved, 1200)

      {:ok, i} =
        Interactions.update_interaction(i, %{"status" => "happened", "occurred_at" => actual})

      assert i.occurred_at == actual
      assert i.planned_at == moved
    end

    test "overdue is a plan past its time, never a stored state", %{company: company} do
      upcoming = plan(company)
      past = plan(company, %{"occurred_at" => @yesterday, "duration_minutes" => 60})

      refute Interaction.overdue?(upcoming)
      assert Interaction.overdue?(past)
      # nothing flipped it
      assert Interactions.get_interaction(past.uuid).status == "planned"

      {:ok, logged} = Interactions.update_interaction(past, %{"status" => "happened"})
      refute Interaction.overdue?(logged)
    end

    test "a cancelled one keeps its note and its length", %{company: company} do
      i = plan(company)

      {:ok, i} =
        Interactions.update_interaction(i, %{
          "status" => "cancelled",
          "body" => "Client cancelled at the door.",
          "duration_minutes" => 120
        })

      assert Interaction.cancelled?(i)
      assert i.duration_minutes == 120
      assert i.body == "Client cancelled at the door."
    end
  end

  describe "the lists" do
    test "a plan is not recent contact and is not counted as logged", %{company: company} do
      {:ok, done} =
        Interactions.create_interaction(%{"company_uuid" => company.uuid, "subject" => "Done"})

      planned = plan(company)

      assert Enum.map(Interactions.list_recent(), & &1.uuid) == [done.uuid]
      assert Interactions.count_interactions() == 1
      assert Enum.map(Interactions.list_planned(), & &1.uuid) == [planned.uuid]
    end

    test "what is planned reads soonest first, an overdue one leading", %{company: company} do
      later = plan(company, %{"occurred_at" => DateTime.add(@tomorrow, 86_400)})
      soon = plan(company)
      overdue = plan(company, %{"occurred_at" => @yesterday})

      assert Enum.map(Interactions.list_planned(), & &1.uuid) ==
               [overdue.uuid, soon.uuid, later.uuid]
    end

    test "a plan on a trashed company is not listed", %{company: company} do
      plan(company)
      {:ok, _} = Companies.trash_company(company)
      assert Interactions.list_planned() == []
    end
  end

  describe "the trail" do
    test "planning, moving, cancelling and logging each leave their own entry", %{
      company: company
    } do
      i = plan(company)

      assert_activity_logged("crm.interaction_planned",
        resource_uuid: company.uuid,
        metadata_has: %{"interaction_uuid" => i.uuid, "status" => "planned"}
      )

      moved = DateTime.add(@tomorrow, 3600)
      {:ok, i} = Interactions.update_interaction(i, %{"occurred_at" => moved})

      assert_activity_logged("crm.interaction_moved",
        resource_uuid: company.uuid,
        metadata_has: %{"moved_from" => DateTime.to_iso8601(@tomorrow)}
      )

      {:ok, i} = Interactions.update_interaction(i, %{"status" => "cancelled"})

      assert_activity_logged("crm.interaction_cancelled",
        resource_uuid: company.uuid,
        metadata_has: %{"status_from" => "planned", "status" => "cancelled"}
      )

      other = plan(company, %{"occurred_at" => @yesterday})
      {:ok, _} = Interactions.update_interaction(other, %{"status" => "happened"})

      assert_activity_logged("crm.interaction_logged",
        resource_uuid: company.uuid,
        metadata_has: %{"interaction_uuid" => other.uuid, "status_from" => "planned"}
      )

      # an ordinary edit of a record is still just an update
      {:ok, _} = Interactions.update_interaction(i, %{"body" => "Rebooked for next week."})

      assert_activity_logged("crm.interaction_updated",
        resource_uuid: company.uuid,
        metadata_has: %{"interaction_uuid" => i.uuid}
      )
    end

    test "the planned entry carries what a notified person reads and where it leads", %{
      company: company
    } do
      plan(company)

      row = assert_activity_logged("crm.interaction_planned", resource_uuid: company.uuid)
      assert row.metadata["notification_text"] =~ "planned meeting"
      assert row.metadata["notification_link"] =~ "#{company.uuid}?tab=interactions"
    end
  end

  describe "who is told" do
    test "the users behind the parties: a linked contact yes, a free-text name no", %{
      company: company
    } do
      {contact, user} = linked_contact("Maria Tamm")
      {:ok, unlinked} = Contacts.create_contact(%{"name" => "No Login"})

      i =
        plan(company, %{}, [
          %{raw_name: "Maria Tamm", contact_uuid: contact.uuid},
          %{raw_name: "No Login", contact_uuid: unlinked.uuid},
          %{raw_name: "Someone typed"}
        ])

      assert InteractionNotifier.party_user_uuids(i) == [user.uuid]
    end

    test "someone added to an existing plan gets their own entry", %{company: company} do
      {contact, _user} = linked_contact("Peeter Kask")
      i = plan(company)

      {:ok, _} =
        Interactions.update_interaction(i, %{}, [
          %{raw_name: "Peeter Kask", contact_uuid: contact.uuid}
        ])

      # the create's entry and the one for the person added
      assert length(
               Repo.query!(
                 "SELECT 1 FROM phoenix_kit_activities WHERE action = 'crm.interaction_planned'"
               ).rows
             ) == 2
    end

    test "a fan-out with nobody to tell, or no entry, is a quiet no-op" do
      assert InteractionNotifier.fan_out({:ok, %{uuid: Ecto.UUID.generate()}}, []) == :ok
      assert InteractionNotifier.fan_out(:error, [Ecto.UUID.generate()]) == :ok
    end
  end

  describe "over the projects API" do
    setup %{company: company} do
      project_uuid = Ecto.UUID.generate()
      ctx = %{project: %{uuid: project_uuid}, user_uuid: nil, key: nil, actor: nil}

      {:ok, done} =
        Interactions.create_interaction(%{
          "company_uuid" => company.uuid,
          "project_uuid" => project_uuid,
          "interaction_type" => "meeting",
          "subject" => "Kickoff",
          "occurred_at" => @yesterday
        })

      planned = plan(company, %{"project_uuid" => project_uuid, "subject" => "Review"})
      {:ok, ctx: ctx, done: done, planned: planned}
    end

    test "the list is the record unless asked; status=planned is the plan", %{
      ctx: ctx,
      done: done,
      planned: planned
    } do
      assert {:ok, %{interactions: [json]}} = ProjectApi.list(ctx, %{})
      assert json.uuid == done.uuid
      assert json.status == "happened"

      assert {:ok, %{interactions: [json]}} = ProjectApi.list(ctx, %{"status" => "planned"})
      assert json.uuid == planned.uuid
      assert json.status == "planned"
      assert json.overdue == false
      assert json.planned_at == @tomorrow

      assert {:ok, %{count: 2}} = ProjectApi.list(ctx, %{"status" => "all"})
      assert {:ok, %{count: 2}} = ProjectApi.list(ctx, %{"status" => "planned, happened"})
      assert {:error, {422, _, _, %{"status" => _}}} = ProjectApi.list(ctx, %{"status" => "soon"})
    end

    test "updated_since finds a plan that changed after it was first seen", %{
      ctx: ctx,
      planned: planned
    } do
      seen = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.to_iso8601()

      assert {:ok, %{count: 0}} =
               ProjectApi.list(ctx, %{"status" => "all", "updated_since" => seen})

      before = DateTime.add(planned.updated_at, -1) |> DateTime.to_iso8601()

      assert {:ok, %{count: 2}} =
               ProjectApi.list(ctx, %{"status" => "all", "updated_since" => before})

      assert {:error, {422, _, _, _}} = ProjectApi.list(ctx, %{"updated_since" => "yesterday"})
    end

    test "a plan is moved, logged and cancelled by PATCH", %{ctx: ctx, planned: planned} do
      moved = DateTime.add(@tomorrow, 7200)

      assert {:ok, %{interaction: json}} =
               ProjectApi.update(ctx, planned.uuid, %{
                 "occurred_at" => DateTime.to_iso8601(moved),
                 "location" => "Their office"
               })

      assert json.status == "planned"
      assert json.occurred_at == moved
      assert json.location == "Their office"

      # it cannot be the record of something still to come
      assert {:error, {422, _, message, %{"occurred_at" => _}}} =
               ProjectApi.update(ctx, planned.uuid, %{"status" => "happened"})

      assert message =~ "future"

      assert {:ok, %{interaction: json}} =
               ProjectApi.update(ctx, planned.uuid, %{
                 "status" => "happened",
                 "occurred_at" => DateTime.to_iso8601(@yesterday),
                 "duration_minutes" => 45
               })

      assert json.status == "happened"
      assert json.planned_at == moved
      assert json.occurred_at == @yesterday

      assert {:ok, %{interaction: %{status: "cancelled"}}} =
               ProjectApi.update(ctx, planned.uuid, %{"status" => "cancelled"})
    end

    test "a logged row goes back to a plan when the project's ledger holds no time on it",
         %{ctx: ctx, planned: planned} do
      # The projects module is not a dependency here, so there is no ledger
      # to refuse it: the guard (`check_replan/3`) lets the change through.
      {:ok, _} =
        Interactions.update_interaction(planned, %{
          "status" => "happened",
          "occurred_at" => @yesterday
        })

      assert {:ok, %{interaction: %{status: "planned"}}} =
               ProjectApi.update(ctx, planned.uuid, %{
                 "status" => "planned",
                 "occurred_at" => DateTime.to_iso8601(@tomorrow)
               })
    end

    test "one cancelled ahead of its time keeps its future start", %{ctx: ctx, planned: planned} do
      assert {:ok, %{interaction: json}} =
               ProjectApi.update(ctx, planned.uuid, %{"status" => "cancelled"})

      assert json.status == "cancelled"
      assert json.occurred_at == @tomorrow
    end

    test "a bad status or an over-long location is a 422", %{ctx: ctx, planned: planned} do
      assert {:error, {422, _, _, %{"status" => _}}} =
               ProjectApi.update(ctx, planned.uuid, %{"status" => "done"})

      assert {:error, {422, _, _, %{"location" => _}}} =
               ProjectApi.update(ctx, planned.uuid, %{"location" => String.duplicate("x", 201)})
    end
  end
end
