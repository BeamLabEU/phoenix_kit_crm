defmodule PhoenixKitCRM.InteractionLinksTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Companies, Contacts, InteractionLinks, Interactions}
  alias PhoenixKitCRM.Schemas.Interaction

  defp company_fixture(name \\ "Acme") do
    {:ok, company} = Companies.create_company(%{"name" => name})
    company
  end

  defp meeting(company, attrs \\ %{}) do
    {:ok, i} =
      Interactions.create_interaction(
        Map.merge(
          %{
            "company_uuid" => company.uuid,
            "interaction_type" => "meeting",
            "occurred_at" => ~U[2026-10-04 14:00:00Z]
          },
          attrs
        )
      )

    i
  end

  describe "label/1" do
    test "the subject when there is one, else the type and the date" do
      assert InteractionLinks.label(%Interaction{subject: "Kickoff"}) == "Kickoff"

      assert InteractionLinks.label(%Interaction{
               interaction_type: "meeting",
               occurred_at: ~U[2026-10-04 14:00:00Z]
             }) == "#{Interaction.type_label("meeting")} · 2026-10-04"
    end
  end

  describe "resolve_comment_resources/1" do
    test "a title and the anchor page's interactions tab, per uuid" do
      company = company_fixture()
      i = meeting(company, %{"subject" => "Kickoff"})
      {:ok, contact} = Contacts.create_contact(%{"name" => "Anna"})

      {:ok, on_contact} =
        Interactions.create_interaction(%{
          "contact_uuid" => contact.uuid,
          "interaction_type" => "call"
        })

      resolved =
        InteractionLinks.resolve_comment_resources([
          i.uuid,
          on_contact.uuid,
          Ecto.UUID.generate()
        ])

      assert %{title: "Kickoff", path: path} = resolved[i.uuid]
      assert path =~ "/companies/#{company.uuid}"
      assert path =~ "tab=interactions"
      assert %{path: contact_path} = resolved[on_contact.uuid]
      assert contact_path =~ "/contacts/#{contact.uuid}"
      assert map_size(resolved) == 2
    end
  end

  describe "search and visibility without an identifiable asker" do
    test "offer nothing and show nothing — fail closed" do
      company = company_fixture()
      i = meeting(company, %{"subject" => "Kickoff"})

      assert InteractionLinks.search_resources("Kick", []) == []
      assert InteractionLinks.search_resources("Kick", user_uuid: Ecto.UUID.generate()) == []
      assert InteractionLinks.visible_resource_uuids([i.uuid], []) == []
    end
  end
end
