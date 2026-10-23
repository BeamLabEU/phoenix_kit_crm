defmodule PhoenixKitCRM.Web.ProjectClientLedgerTest do
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Interactions, ProjectApi}
  alias PhoenixKitCRM.Web.ProjectClientLive

  @project "0199a0e0-0000-7000-8000-0000000000fd"
  @ledger_state PhoenixKitCRM.Test.ClientLedgerState

  # The optional package is absent from this suite. Load a small in-memory
  # collaborator only for this synchronous module, then unload it. These
  # tests exercise the real drawer, bridge calls and retry behavior without
  # adding a dependency on projects or changing the production bridge.
  setup_all do
    refute Code.ensure_loaded?(PhoenixKitProjects.Ledger)
    refute Code.ensure_loaded?(PhoenixKitProjects.ProjectEvents)

    Code.compile_quoted(
      quote do
        defmodule PhoenixKitProjects.Ledger do
          def list_entries(_, _) do
            state = Agent.get(PhoenixKitCRM.Test.ClientLedgerState, & &1)
            if state.fail_read, do: raise("ledger read failed")
            Map.values(state.entries)
          end

          def log_time(_, minutes, opts) do
            Agent.get_and_update(PhoenixKitCRM.Test.ClientLedgerState, fn state ->
              if opts[:actor_uuid] == state.fail_actor do
                {{:error, :rejected}, state}
              else
                entry = %{
                  uuid: Ecto.UUID.generate(),
                  kind: "time",
                  actor_kind: opts[:actor_kind],
                  actor_uuid: opts[:actor_uuid],
                  amount: Decimal.new(minutes),
                  billable: opts[:billable],
                  metadata: opts[:metadata]
                }

                {{:ok, entry}, put_in(state.entries[entry.uuid], entry)}
              end
            end)
          end

          def update_time(uuid, minutes, opts) do
            Agent.get_and_update(PhoenixKitCRM.Test.ClientLedgerState, fn state ->
              entry = %{
                state.entries[uuid]
                | amount: Decimal.new(minutes),
                  billable: opts[:billable]
              }

              {{:ok, entry}, put_in(state.entries[uuid], entry)}
            end)
          end

          def delete_entry(uuid, _) do
            Agent.get_and_update(PhoenixKitCRM.Test.ClientLedgerState, fn state ->
              {entry, entries} = Map.pop(state.entries, uuid)
              {{:ok, entry}, %{state | entries: entries}}
            end)
          end
        end

        defmodule PhoenixKitProjects.ProjectEvents do
          def list_for_project(_, _),
            do: Agent.get(PhoenixKitCRM.Test.ClientLedgerState, & &1.events)
        end
      end
    )

    on_exit(fn ->
      for mod <- [PhoenixKitProjects.Ledger, PhoenixKitProjects.ProjectEvents] do
        :code.purge(mod)
        :code.delete(mod)
      end
    end)

    :ok
  end

  setup %{conn: conn} do
    start_supervised!(
      {Agent, fn -> %{entries: %{}, fail_actor: nil, fail_read: false, events: []} end},
      id: @ledger_state
    )
    |> then(&:erlang.register(@ledger_state, &1))

    {:ok, user} =
      Auth.register_user(%{
        "email" => "ledger-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24",
        "first_name" => "Vera",
        "last_name" => "Viewer"
      })

    {:ok, company} = Companies.create_company(%{"name" => "Ledger client"})
    staff = Ecto.UUID.generate()

    {:ok, row} =
      Interactions.create_interaction(
        %{
          "company_uuid" => company.uuid,
          "project_uuid" => @project,
          "interaction_type" => "meeting",
          "subject" => "Ledger meeting",
          "duration_minutes" => 60
        },
        [%{raw_name: "Staff attendee", staff_person_uuid: staff}]
      )

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))

    {:ok, view, _} =
      live_isolated(conn, ProjectClientLive,
        session: %{
          "project_uuid" => @project,
          "config" => %{"company_uuid" => company.uuid},
          "can_write" => true,
          "current_user_uuid" => user.uuid,
          "locale" => "en"
        }
      )

    %{view: view, row: row, staff: staff, user: user}
  end

  test "an unchanged staff attendee is not logged again", context do
    entry = seed_time(context, context.staff, false)
    composer = edit(context)
    context.view |> with_target(composer) |> render_click("save_interaction", %{})
    assert entries() == [entry]
  end

  test "a billable-only edit amends the existing entry", context do
    entry = seed_time(context, context.staff, false)
    composer = edit(context)
    change(context.view, composer, "true", %{})
    context.view |> with_target(composer) |> render_click("save_interaction", %{})
    assert [%{uuid: uuid, billable: true, amount: amount}] = entries()
    assert uuid == entry.uuid and Decimal.equal?(amount, 60)
  end

  test "changing minutes preserves a mixed set's individual billable flags", context do
    nonbillable = seed_time(context, context.staff, false)
    second_staff = Ecto.UUID.generate()
    billable = seed_time(context, second_staff, true)

    {:ok, _} =
      Interactions.update_interaction(context.row, %{}, [
        %{raw_name: "Staff attendee", staff_person_uuid: context.staff},
        %{raw_name: "Other staff", staff_person_uuid: second_staff}
      ])

    composer = edit(context)
    change(context.view, composer, "true", %{"staff_person:#{context.staff}" => "90"})
    context.view |> with_target(composer) |> render_click("save_interaction", %{})
    rows = Map.new(entries(), &{&1.uuid, &1})
    assert rows[billable.uuid] == billable
    assert rows[nonbillable.uuid].billable == false
    assert Decimal.equal?(rows[nonbillable.uuid].amount, 90)
  end

  test "a partial ledger failure preserves the meeting and retry does not duplicate time",
       context do
    Agent.update(@ledger_state, &%{&1 | fail_actor: context.staff})
    render_click(context.view, "open_composer", %{})
    composer = composer_id(render(context.view))
    context.view |> with_target(composer) |> render_click("add_me", %{})

    context.view
    |> with_target(composer)
    |> render_click("stage_party", %{
      "kind" => "staff",
      "uuid" => context.staff,
      "label" => "Staff attendee"
    })

    change(context.view, composer, "true", %{})
    context.view |> with_target(composer) |> render_click("save_interaction", %{})
    html = render(context.view)
    assert html =~ "1 time entries could not be written"
    # the composer stays open on the saved row: a retry amends it
    assert html =~ "Save changes"
    assert html =~ "Retry meeting"
    assert length(Interactions.list_for_project(@project)) == 2
    assert [%{actor_uuid: viewer}] = entries()
    assert viewer == context.user.uuid

    Agent.update(@ledger_state, &%{&1 | fail_actor: nil})
    context.view |> with_target(composer) |> render_click("save_interaction", %{})
    refute render(context.view) =~ "crm-project-composer-"
    assert length(Interactions.list_for_project(@project)) == 2
    assert length(entries()) == 2
    assert Enum.uniq(Enum.map(entries(), & &1.metadata["interaction_uuid"])) |> length() == 1
  end

  test "a ledger read failure refuses an edit save rather than logging duplicate time", context do
    entry = seed_time(context, context.staff, false)
    Agent.update(@ledger_state, &%{&1 | fail_read: true})
    composer = edit(context)
    assert render(context.view) =~ "Time entries could not be loaded"
    change(context.view, composer, "true", %{})
    context.view |> with_target(composer) |> render_click("save_interaction", %{})
    assert Interactions.get_interaction(context.row.uuid).subject == "Ledger meeting"
    assert entries() == [entry]
  end

  test "the API refuses re-planning a row with logged time or an unreadable ledger", context do
    entry = seed_time(context, context.staff, false)
    ctx = %{project: %{uuid: @project}, user_uuid: context.user.uuid}

    assert {:error, {422, _, _, %{"status" => _}}} =
             ProjectApi.update(ctx, context.row.uuid, %{"status" => "planned"})

    assert Interactions.get_interaction(context.row.uuid).status == "happened"
    assert entries() == [entry]

    Agent.update(@ledger_state, &%{&1 | entries: %{}, fail_read: true})

    assert {:error, {422, _, _, %{"status" => _}}} =
             ProjectApi.update(ctx, context.row.uuid, %{"status" => "planned"})

    assert Interactions.get_interaction(context.row.uuid).status == "happened"
  end

  test "a plan made elsewhere shows under Planned; a calendar event is not a meeting to log",
       context do
    event = %{
      uuid: Ecto.UUID.generate(),
      title: "Milestone on the calendar",
      location: nil,
      starts_at: ~U[2026-10-04 11:00:00Z]
    }

    Agent.update(@ledger_state, &%{&1 | events: [event]})
    send(context.view.pid, {:projects, :project_event_created, %{uuid: @project}})
    refute render(context.view) =~ "Milestone on the calendar"

    {:ok, plan} =
      Interactions.create_interaction(%{
        "company_uuid" => context.row.company_uuid,
        "project_uuid" => @project,
        "interaction_type" => "meeting",
        "subject" => "Planned elsewhere",
        "status" => "planned",
        "occurred_at" => DateTime.add(DateTime.utc_now(), 86_400)
      })

    html = render(context.view)
    assert html =~ ~s(id="crm-planned-#{plan.uuid}")
    assert html =~ "Planned elsewhere"
  end

  test "a plan logs no time; logging what happened does, once", context do
    feed = "#crm-project-interactions-#{@project}"
    context.view |> with_target(feed) |> render_click("start_planning", %{})
    composer = composer_id(render(context.view))

    context.view
    |> with_target(composer)
    |> render_click("stage_party", %{
      "kind" => "staff",
      "uuid" => context.staff,
      "label" => "Staff attendee"
    })

    context.view
    |> with_target(composer)
    |> render_change("composer_change", %{
      "interaction" => %{
        "subject" => "Planned visit",
        "occurred_at" => "2031-03-04T10:00",
        "duration_minutes" => "60"
      }
    })

    html = render(context.view)
    # nothing has been spent yet: no billable switch, no minutes boxes
    refute html =~ ~s(id="crm-billable")
    assert html =~ "Time is logged on the project once this is saved as happened or cancelled."

    context.view |> with_target(composer) |> render_click("save_interaction", %{})
    assert entries() == []

    assert [plan] =
             Enum.filter(Interactions.list_for_project(@project), &(&1.status == "planned"))

    assert plan.subject == "Planned visit"

    # "Log what happened": the same row, now with its time
    context.view |> with_target(feed) |> render_click("log_planned", %{"uuid" => plan.uuid})
    composer = composer_id(render(context.view))

    context.view
    |> with_target(composer)
    |> render_change("composer_change", %{
      "interaction" => %{
        "subject" => "Planned visit",
        "occurred_at" => "2026-10-04T10:00",
        "duration_minutes" => "60"
      },
      # the start is what was just changed: the end follows it
      "_target" => ["interaction", "occurred_at"]
    })

    context.view |> with_target(composer) |> render_click("save_interaction", %{})

    assert Interactions.get_interaction(plan.uuid).status == "happened"
    assert [%{actor_uuid: actor, metadata: %{"interaction_uuid" => uuid}}] = entries()
    assert actor == context.staff and uuid == plan.uuid
    assert length(Interactions.list_for_project(@project)) == 2
  end

  defp seed_time(context, actor_uuid, billable) do
    {:ok, entry} =
      PhoenixKitCRM.ProjectsLink.log_time(@project, 60,
        actor_kind: "staff_person",
        actor_uuid: actor_uuid,
        billable: billable,
        metadata: %{"interaction_uuid" => context.row.uuid}
      )

    entry
  end

  defp entries, do: Agent.get(@ledger_state, &Map.values(&1.entries))

  defp edit(context) do
    context.view
    |> with_target("#crm-project-interactions-#{@project}")
    |> render_click("edit_interaction", %{"uuid" => context.row.uuid})

    composer_id(render(context.view))
  end

  defp composer_id(html) do
    [_, id] = Regex.run(~r/id="(crm-project-composer-[^"]+-\d+)"/, html)
    "#" <> id
  end

  defp change(view, composer, billable, minutes) do
    view
    |> with_target(composer)
    |> render_change("composer_change", %{
      "interaction" => %{
        "subject" => "Retry meeting",
        "duration_minutes" => "60",
        "billable" => billable
      },
      "attendee_minutes" => minutes
    })
  end
end
