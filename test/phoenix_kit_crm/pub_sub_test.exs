defmodule PhoenixKitCRM.PubSubTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCRM.PubSub
  alias PhoenixKitCRM.Schemas.{Interaction, InteractionParty}

  test "project broadcasts work for either anchor and skip unrelated projects" do
    project_uuid = Ecto.UUID.generate()
    :ok = PubSub.subscribe(PubSub.topic_project_interactions(project_uuid))
    on_exit(fn -> PubSub.unsubscribe(PubSub.topic_project_interactions(project_uuid)) end)

    for anchor <- [:contact_uuid, :company_uuid] do
      interaction =
        struct(Interaction, %{
          anchor => Ecto.UUID.generate(),
          :uuid => Ecto.UUID.generate(),
          :project_uuid => project_uuid
        })

      :ok = PubSub.broadcast_interaction(:interaction_created, interaction)
      assert_receive {:crm, :interaction_created, %{interaction_uuid: uuid}}
      assert uuid == interaction.uuid
    end

    :ok = PubSub.broadcast_to_project_feed(:interaction_updated, Ecto.UUID.generate(), nil)

    :ok =
      PubSub.broadcast_to_project_feed(
        :interaction_updated,
        Ecto.UUID.generate(),
        Ecto.UUID.generate()
      )

    refute_receive {:crm, :interaction_updated, _}
  end

  describe "involved_contact_uuids/1" do
    test "returns the subject plus party contact uuids, deduped, nils dropped" do
      interaction = %Interaction{
        contact_uuid: "subject-uuid",
        parties: [
          %InteractionParty{contact_uuid: "party-1"},
          # free-text party (no resolved contact)
          %InteractionParty{contact_uuid: nil},
          # a party that is also the subject
          %InteractionParty{contact_uuid: "subject-uuid"}
        ]
      }

      assert PubSub.involved_contact_uuids(interaction) == ["subject-uuid", "party-1"]
    end

    test "treats a not-loaded parties association as no parties" do
      interaction = %Interaction{contact_uuid: "s", parties: %Ecto.Association.NotLoaded{}}
      assert PubSub.involved_contact_uuids(interaction) == ["s"]
    end
  end
end
