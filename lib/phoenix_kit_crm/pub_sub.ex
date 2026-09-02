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

  @doc """
  A company's interaction feed — company-ANCHORED interactions only, the
  symmetric twin of `topic_contact_interactions/1`. Deliberately not the
  general `topic_company/1` topic: that one signals record/roster changes and
  triggers heavier reloads than a feed refresh needs.
  """
  @spec topic_company_interactions(binary()) :: String.t()
  def topic_company_interactions(company_uuid), do: "crm:company:#{company_uuid}:interactions"

  @doc "Topic for CRM contact-list live updates (membership changes, counters)."
  @spec topic_lists() :: String.t()
  def topic_lists, do: "crm:lists"

  @doc """
  Topic for one company's live page: its member roster (a contact joining,
  leaving, being trashed/restored/deleted, or renamed) — `{:crm, event,
  %{contact_uuid: uuid}}` with `event` one of `:member_joined |
  :member_left | :member_changed`.
  """
  @spec topic_company(binary()) :: String.t()
  def topic_company(company_uuid), do: "crm:company:#{company_uuid}"

  @doc "Subscribes the calling process to a topic."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic), do: Manager.subscribe(topic)

  @doc "Unsubscribes the calling process from a topic."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic), do: Manager.unsubscribe(topic)

  @doc """
  Subscribes to a topic on the HOST app's PubSub — the server other
  phoenix_kit modules broadcast on through `PhoenixKit.PubSubHelper`
  (the catalogue's `"phoenix_kit_catalogue"` topic). CRM's own topics live
  on core's internal server (`subscribe/1`); a cross-module subscription
  made there never hears anything (review finding, 2026-08-24).
  """
  @spec subscribe_host(String.t()) :: :ok | {:error, term()}
  def subscribe_host(topic), do: PhoenixKit.PubSubHelper.subscribe(topic)

  @spec unsubscribe_host(String.t()) :: :ok
  def unsubscribe_host(topic),
    do: Phoenix.PubSub.unsubscribe(PhoenixKit.PubSubHelper.pubsub(), topic)

  @doc """
  Fans an interaction change out to every involved contact's feed topic.

  Best-effort: never raises out to the caller — a saved interaction must not be
  reported as failed just because the realtime broadcast hiccuped. Call it
  AFTER the DB commit.
  """
  @spec broadcast_interaction(atom(), Interaction.t()) :: :ok
  def broadcast_interaction(event, %Interaction{} = interaction) do
    broadcast_to_contacts(event, interaction.uuid, involved_contact_uuids(interaction))
    broadcast_to_company_feed(event, interaction.uuid, interaction.company_uuid)
  end

  @doc """
  A company's soft-delete state flipped, so its anchored interactions just
  (dis)appeared from involving feeds — sent to each affected party contact's
  feed topic. Best-effort (rescued).
  """
  @spec broadcast_company_visibility(binary(), [binary()]) :: :ok
  def broadcast_company_visibility(company_uuid, contact_uuids) do
    msg = {:crm, :company_visibility_changed, %{company_uuid: company_uuid}}

    contact_uuids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Manager.broadcast(topic_contact_interactions(&1), msg))

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Broadcasts an interaction change to a company's interaction-feed topic —
  a no-op for contact-anchored interactions (`company_uuid` nil). The anchor
  is immutable, so updates and deletes reach the same topic creates did.
  Best-effort (rescued), like every broadcast here.
  """
  @spec broadcast_to_company_feed(atom(), binary(), binary() | nil) :: :ok
  def broadcast_to_company_feed(_event, _interaction_uuid, nil), do: :ok

  def broadcast_to_company_feed(event, interaction_uuid, company_uuid) do
    Manager.broadcast(
      topic_company_interactions(company_uuid),
      {:crm, event, %{interaction_uuid: interaction_uuid}}
    )

    :ok
  rescue
    _ -> :ok
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
  Fans a contact change out to the companies it is (or was) a member of, so
  each company's page can refresh its roster. Best-effort (rescued). Call it
  AFTER the DB commit.
  """
  @spec broadcast_company_event(atom(), [binary()], binary()) :: :ok
  def broadcast_company_event(event, company_uuids, contact_uuid) do
    msg = {:crm, event, %{contact_uuid: contact_uuid}}

    company_uuids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Manager.broadcast(topic_company(&1), msg))

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
