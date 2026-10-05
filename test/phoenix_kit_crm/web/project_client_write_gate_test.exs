defmodule PhoenixKitCRM.Web.ProjectClientWriteGateTest do
  @moduledoc """
  The Client tab's `can_write: false` (the hub's verdict for a viewer without
  the extension's `log_interaction` action) hides every write control — and
  must also refuse the events behind them: a LiveView event is a message any
  client can send, hidden button or not.
  """

  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Contacts, Interactions}
  alias PhoenixKitCRM.Web.ProjectClientLive

  @project "0199a0e0-0000-7000-8000-0000000000fe"

  defp mount_tab(conn, can_write) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "viewer-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24",
        "first_name" => "Vera",
        "last_name" => "Viewer"
      })

    {:ok, company} = Companies.create_company(%{"name" => "Globex"})

    {:ok, row} =
      Interactions.create_interaction(
        %{
          "company_uuid" => company.uuid,
          "interaction_type" => "call",
          "subject" => "Kept call",
          "occurred_at" => DateTime.utc_now(),
          "project_uuid" => @project,
          "owner_user_uuid" => user.uuid
        },
        []
      )

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))

    {:ok, view, _html} =
      live_isolated(conn, ProjectClientLive,
        session: %{
          "project_uuid" => @project,
          "config" => %{"company_uuid" => company.uuid},
          "can_write" => can_write,
          "current_user_uuid" => user.uuid,
          "locale" => "en"
        }
      )

    {view, row}
  end

  defp feed(view), do: with_target(view, "#crm-project-interactions-#{@project}")

  test "a viewer without can_write cannot delete, save or compose through forged events",
       %{conn: conn} do
    {view, row} = mount_tab(conn, false)
    assert render(view) =~ "Kept call"

    feed(view) |> render_click("delete_interaction", %{"uuid" => row.uuid})
    assert Interactions.get_interaction(row.uuid)

    feed(view) |> render_change("composer_change", %{"interaction" => %{"subject" => "Forged"}})
    feed(view) |> render_click("save_interaction", %{})
    assert [%{subject: "Kept call"}] = Interactions.list_for_project(@project)

    feed(view) |> render_click("edit_interaction", %{"uuid" => row.uuid})
    render_click(view, "open_composer", %{})
    refute render(view) =~ "crm-project-composer-"
  end

  test "Edit only opens a row this page is the anchor of, even for a forged event", %{conn: conn} do
    {view, _row} = mount_tab(conn, true)
    {:ok, contact} = Contacts.create_contact(%{"name" => "Someone Else"})

    {:ok, spill} =
      Interactions.create_interaction(
        %{
          "contact_uuid" => contact.uuid,
          "interaction_type" => "call",
          "subject" => "Contact's own call",
          "occurred_at" => DateTime.utc_now(),
          "project_uuid" => @project
        },
        []
      )

    # A reload picks the new row up; it is listed (project rows are) but is
    # not this company's to edit.
    feed(view) |> render_click("set_feed_scope", %{"scope" => "all"})
    send(view.pid, {:crm, :interaction_created, %{interaction_uuid: spill.uuid}})
    assert render(view) =~ "Contact&#39;s own call"

    feed(view) |> render_click("edit_interaction", %{"uuid" => spill.uuid})
    refute render(view) =~ "crm-project-composer-"
    refute render(view) =~ "as logged on the project"
  end

  test "the project feed follows contact and former-client changes over PubSub", %{conn: conn} do
    {view, _row} = mount_tab(conn, false)
    {:ok, contact} = Contacts.create_contact(%{"name" => "Project attendee"})
    {:ok, former_client} = Companies.create_company(%{"name" => "Former client"})

    for anchor <- [contact_uuid: contact.uuid, company_uuid: former_client.uuid] do
      {field, uuid} = anchor

      {:ok, row} =
        Interactions.create_interaction(%{
          Atom.to_string(field) => uuid,
          "project_uuid" => @project,
          "subject" => "Arrived through the project topic"
        })

      assert render(view) =~ "Arrived through the project topic"

      {:ok, updated} =
        Interactions.update_interaction(row, %{"subject" => "Updated through the project topic"})

      assert render(view) =~ "Updated through the project topic"
      {:ok, _} = Interactions.delete_interaction(updated)
      refute render(view) =~ "Updated through the project topic"
    end
  end

  test "trashing and restoring either anchor updates the project feed", %{conn: conn} do
    {view, _row} = mount_tab(conn, false)
    {:ok, contact} = Contacts.create_contact(%{"name" => "Visibility contact"})
    {:ok, company} = Companies.create_company(%{"name" => "Visibility company"})

    for {kind, record, context} <- [
          {"contact_uuid", contact, Contacts},
          {"company_uuid", company, Companies}
        ] do
      {:ok, _} =
        Interactions.create_interaction(%{
          kind => record.uuid,
          "project_uuid" => @project,
          "subject" => "Visibility meeting"
        })

      assert render(view) =~ "Visibility meeting"
      # Each context's public soft-delete operation emits after commit.
      {:ok, trashed} =
        if context == Contacts,
          do: Contacts.trash_contact(record),
          else: Companies.trash_company(record)

      refute render(view) =~ "Visibility meeting"

      {:ok, restored} =
        if context == Contacts,
          do: Contacts.restore_contact(trashed),
          else: Companies.restore_company(trashed)

      assert render(view) =~ "Visibility meeting"

      {:ok, _} =
        if context == Contacts,
          do: Contacts.delete_contact(restored),
          else: Companies.delete_company(restored)

      refute render(view) =~ "Visibility meeting"
    end
  end

  test "with can_write the same delete goes through", %{conn: conn} do
    {view, row} = mount_tab(conn, true)

    feed(view) |> render_click("delete_interaction", %{"uuid" => row.uuid})
    assert Interactions.get_interaction(row.uuid) == nil
  end
end
