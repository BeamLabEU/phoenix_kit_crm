defmodule PhoenixKitCRM.CalendarItemsTest do
  @moduledoc """
  Interactions as read-only calendar items: a project's, for its Calendar
  tab, and a person's — the ones they wrote or are a party to — for their
  own calendar. Never anyone else's.
  """

  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{CalendarItems, Companies, Contacts, Interactions}

  @from ~U[2026-10-01 00:00:00Z]
  @until ~U[2026-11-01 00:00:00Z]

  setup do
    {:ok, company} = Companies.create_company(%{"name" => "Acme"})
    {:ok, company: company}
  end

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "cal-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    user
  end

  defp interaction(company, attrs, parties \\ []) do
    {:ok, i} =
      Interactions.create_interaction(
        Map.merge(
          %{
            "company_uuid" => company.uuid,
            "interaction_type" => "meeting",
            "occurred_at" => ~U[2026-10-12 09:00:00Z]
          },
          attrs
        ),
        parties
      )

    i
  end

  describe "for_project/3" do
    test "the project's interactions in the window, soonest first, as plain maps", %{
      company: company
    } do
      project = Ecto.UUID.generate()

      later =
        interaction(company, %{
          "project_uuid" => project,
          "subject" => "Review",
          "status" => "planned",
          "occurred_at" => ~U[2026-10-20 12:00:00Z],
          "duration_minutes" => 90,
          "location" => "Their office"
        })

      sooner = interaction(company, %{"project_uuid" => project, "status" => "cancelled"})
      _other_project = interaction(company, %{"project_uuid" => Ecto.UUID.generate()})

      _outside =
        interaction(company, %{
          "project_uuid" => project,
          "occurred_at" => ~U[2026-12-01 09:00:00Z]
        })

      assert %{items: [a, b], truncated: false} =
               CalendarItems.for_project(project, @from, @until)

      assert a.id == sooner.uuid
      assert a.status == "cancelled"
      # no subject: the kind and who it is with
      assert a.title == "Meeting — Acme"
      assert a.ends_at == nil

      assert b == %{
               source: "crm",
               id: later.uuid,
               title: "Review",
               label: "Meeting",
               starts_at: ~U[2026-10-20 12:00:00Z],
               ends_at: ~U[2026-10-20 13:30:00Z],
               all_day: false,
               status: "planned",
               location: "Their office",
               url: b.url,
               updated_at: later.updated_at
             }

      assert b.url =~ "#{company.uuid}?tab=interactions"
    end

    test "one that began before the window and runs into it is in; one that ended before is out",
         %{company: company} do
      project = Ecto.UUID.generate()

      spans =
        interaction(company, %{
          "project_uuid" => project,
          "occurred_at" => ~U[2026-09-30 23:00:00Z],
          "duration_minutes" => 120
        })

      _ended =
        interaction(company, %{
          "project_uuid" => project,
          "occurred_at" => ~U[2026-09-30 20:00:00Z],
          "duration_minutes" => 60
        })

      assert %{items: [item]} = CalendarItems.for_project(project, @from, @until)
      assert item.id == spans.uuid
    end

    test "a trashed anchor's interactions are not items; a bad uuid is an empty answer", %{
      company: company
    } do
      project = Ecto.UUID.generate()
      interaction(company, %{"project_uuid" => project})
      {:ok, _} = Companies.trash_company(company)

      assert CalendarItems.for_project(project, @from, @until) == %{items: [], truncated: false}
      assert CalendarItems.for_project("nope", @from, @until) == %{items: [], truncated: false}
    end
  end

  describe "for_user/3" do
    test "what the user wrote and what names them through their contact — nothing else", %{
      company: company
    } do
      me = user()
      {:ok, contact} = Contacts.create_contact(%{"name" => "Me Myself"})
      {:ok, contact, _} = Contacts.connect_user(contact, me.email)

      mine = interaction(company, %{"subject" => "I logged this", "owner_user_uuid" => me.uuid})

      tagged =
        interaction(
          company,
          %{"subject" => "I am in this", "occurred_at" => ~U[2026-10-13 09:00:00Z]},
          [%{raw_name: "Me Myself", contact_uuid: contact.uuid}]
        )

      {:ok, stranger} = Contacts.create_contact(%{"name" => "Someone Else"})

      _not_mine =
        interaction(company, %{"subject" => "Not mine"}, [
          %{raw_name: "Someone Else", contact_uuid: stranger.uuid},
          # my name typed as free text reaches nobody
          %{raw_name: "Me Myself"}
        ])

      assert %{items: items, truncated: false} = CalendarItems.for_user(me.uuid, @from, @until)
      assert Enum.map(items, & &1.id) == [mine.uuid, tagged.uuid]

      # someone with no part in anything sees nothing
      assert CalendarItems.for_user(user().uuid, @from, @until) == %{items: [], truncated: false}
      assert CalendarItems.for_user("nope", @from, @until) == %{items: [], truncated: false}
    end
  end

  test "the CRM declares itself as a calendar source with the user list" do
    assert [%{key: "crm", module_key: "crm", items: {CalendarItems, :for_user}, label: label}] =
             PhoenixKitCRM.phoenix_kit_calendar_sources()

    assert is_binary(label)
  end
end
