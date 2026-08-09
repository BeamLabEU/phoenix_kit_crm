defmodule PhoenixKitCRM.PubSub do
  @moduledoc """
  Real-time updates for CRM interactions, backed by `PhoenixKit.PubSub.Manager`.

  An interaction appears in the feed of every contact it involves — the subject
  contact (`interactions.contact_uuid`) and any resolved **party** contacts — so
  a change fans out to each of their per-contact topics. A contact's
  Interactions tab subscribes to its own topic; any add/edit/delete to an
  interaction touching that contact pushes a live refresh.

  Messages are `{:crm, event, payload}` tuples where `event` is one of
  `:interaction_created | :interaction_updated | :interaction_deleted` and
  `payload` is `%{interaction_uuid: uuid}`.

  Topics are global (no tenant partitioning) — but the per-contact topic is keyed
  by uuid, so you can't subscribe without already knowing the contact, which
  bounds the fan-out. (Mirrors `phoenix_kit_projects` — tenant scoping is a
  framework-wide gap, not a CRM one.)
  """

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKitCRM.Schemas.Interaction

  @doc "Topic for the interaction feed of a single contact (as subject or party)."
  @spec topic_contact_interactions(binary()) :: String.t()
  def topic_contact_interactions(contact_uuid), do: "crm:contact:#{contact_uuid}:interactions"

  @doc "Topic for CRM contact-list live updates (membership changes, counters)."
  @spec topic_lists() :: String.t()
  def topic_lists, do: "crm:lists"

  @doc "Subscribes the calling process to a topic."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic), do: Manager.subscribe(topic)

  @doc "Unsubscribes the calling process from a topic."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic), do: Manager.unsubscribe(topic)

  @doc """
  Fans an interaction change out to every involved contact's feed topic.

  Best-effort: never raises out to the caller — a saved interaction must not be
  reported as failed just because the realtime broadcast hiccuped. Call it
  AFTER the DB commit.
  """
  @spec broadcast_interaction(atom(), Interaction.t()) :: :ok
  def broadcast_interaction(event, %Interaction{} = interaction) do
    broadcast_to_contacts(event, interaction.uuid, involved_contact_uuids(interaction))
  end

  @doc """
  Broadcasts an interaction change to an EXPLICIT set of contact feed topics.

  Used by updates, which must reach the union of the old and new involved
  contacts so a contact dropped by an edit still gets a refresh to remove the
  entry. Best-effort (rescued).
  """
  @spec broadcast_to_contacts(atom(), binary(), [binary()]) :: :ok
  def broadcast_to_contacts(event, interaction_uuid, contact_uuids) do
    msg = {:crm, event, %{interaction_uuid: interaction_uuid}}

    contact_uuids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Manager.broadcast(topic_contact_interactions(&1), msg))

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Broadcasts a CRM list event on the global `crm:lists` topic — `{:crm, event,
  payload}`, same tuple shape as `broadcast_interaction/2`.

  NET-NEW for CRM: `PhoenixKitCRM.PartyRoles` deliberately doesn't broadcast
  (see its moduledoc), but list membership counters are shown live in the
  admin UI, so `PhoenixKitCRM.Lists` broadcasts here on every mutation.

  Best-effort: never raises out to the caller. Call it AFTER the DB commit.
  """
  @spec broadcast_list_event(atom(), map()) :: :ok
  def broadcast_list_event(event, payload) when is_atom(event) and is_map(payload) do
    Manager.broadcast(topic_lists(), {:crm, event, payload})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Subject contact + any resolved party contacts (deduped, nils dropped).
  Tolerates parties not being preloaded (treats them as none).
  """
  @spec involved_contact_uuids(Interaction.t()) :: [binary()]
  def involved_contact_uuids(%Interaction{contact_uuid: subject, parties: parties}) do
    party_uuids =
      case parties do
        list when is_list(list) -> Enum.map(list, & &1.contact_uuid)
        _ -> []
      end

    [subject | party_uuids]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
