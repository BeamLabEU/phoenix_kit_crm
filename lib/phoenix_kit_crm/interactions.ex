defmodule PhoenixKitCRM.Interactions do
  @moduledoc """
  Context for CRM interactions — the History/Interactions tab.

  Handles the logged interaction itself, its resolvable "involved parties"
  (flat list, no per-party role), the as-of-then `party_snapshot` captured on
  save, and the reverse "all interactions involving this contact" query
  (subject OR party).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.Activity
  alias PhoenixKitCRM.Attachments
  alias PhoenixKitCRM.Contacts
  alias PhoenixKitCRM.PubSub
  alias PhoenixKitCRM.Schemas.{Contact, Interaction, InteractionParty}
  alias PhoenixKitCRM.StaffLink

  defp repo, do: RepoHelper.repo()

  @doc """
  Lists every interaction that involves the given contact — whether they are
  the **subject** (`interactions.contact_uuid`) or an **involved party**
  (`interaction_parties.contact_uuid`). Newest first; parties preloaded.
  """
  @spec list_involving(UUIDv7.t() | String.t() | nil) :: [Interaction.t()]
  def list_involving(contact_uuid) do
    case Ecto.UUID.cast(contact_uuid) do
      {:ok, _} ->
        party_subq =
          from(p in InteractionParty,
            where: p.contact_uuid == ^contact_uuid,
            select: p.interaction_uuid
          )

        Interaction
        |> where([i], i.contact_uuid == ^contact_uuid or i.uuid in subquery(party_subq))
        |> order_by([i], desc: i.occurred_at, desc: i.inserted_at)
        |> repo().all()
        |> repo().preload(parties: from(p in InteractionParty, order_by: p.position))

      :error ->
        []
    end
  end

  @doc "UUIDs of the interactions a contact is the subject of (for the Files rollup)."
  @spec interaction_uuids_for_contact(binary()) :: [binary()]
  def interaction_uuids_for_contact(contact_uuid) do
    case Ecto.UUID.cast(contact_uuid) do
      {:ok, _} ->
        from(i in Interaction, where: i.contact_uuid == ^contact_uuid, select: i.uuid)
        |> repo().all()

      :error ->
        []
    end
  end

  @doc """
  Interactions logged on any of the given contacts (as subject), newest first,
  with the subject contact + parties preloaded. Powers the company's aggregated
  read-only interactions feed.

  ## Options
    * `:limit` — cap the rows read. Callers that only show the newest few
      (the projects Client tab) must pass it: without a limit this reads the
      company's whole interaction history, preloads included, to throw all
      but the head away.
  """
  @spec list_for_contacts([binary()], keyword()) :: [Interaction.t()]
  def list_for_contacts(contact_uuids, opts \\ [])

  def list_for_contacts([], _opts), do: []

  def list_for_contacts(contact_uuids, opts) do
    Interaction
    |> where([i], i.contact_uuid in ^contact_uuids)
    |> order_by([i], desc: i.occurred_at, desc: i.inserted_at)
    |> maybe_limit(opts[:limit])
    |> repo().all()
    |> repo().preload([:contact, parties: from(p in InteractionParty, order_by: p.position)])
  end

  defp maybe_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)
  defp maybe_limit(query, _), do: query

  @doc "Total logged interactions. Interactions have no soft-delete status."
  @spec count_interactions() :: non_neg_integer()
  def count_interactions, do: repo().aggregate(Interaction, :count, :uuid)

  @spec get_interaction(UUIDv7.t() | String.t() | nil) :: Interaction.t() | nil
  def get_interaction(uuid) do
    with {:ok, _} <- Ecto.UUID.cast(uuid),
         %Interaction{} = interaction <- repo().get(Interaction, uuid) do
      repo().preload(interaction, [:parties])
    else
      _ -> nil
    end
  end

  @spec change_interaction(Interaction.t(), map()) :: Ecto.Changeset.t()
  def change_interaction(%Interaction{} = interaction, attrs \\ %{}),
    do: Interaction.changeset(interaction, attrs)

  @doc """
  Creates an interaction and (re)builds its party list. `party_inputs` is a
  list of maps with `:raw_name` (required) and an optional resolved reference
  (`:contact_uuid` OR `:staff_person_uuid`). The snapshot is captured here.
  """
  @spec create_interaction(map(), [map()], [binary()]) ::
          {:ok, Interaction.t()} | {:error, Ecto.Changeset.t()}
  def create_interaction(attrs, party_inputs \\ [], file_uuids \\ []) do
    result =
      repo().transaction(fn ->
        case %Interaction{} |> Interaction.changeset(attrs) |> repo().insert() do
          {:ok, interaction} ->
            replace_parties(interaction, party_inputs)
            repo().preload(interaction, [:parties], force: true)

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, interaction} = ok ->
        # Attach staged files + log the audit entry BEFORE broadcasting, so a
        # subscriber reloading off the broadcast already sees both the attached
        # files (rendered from the folder) and the Events-tab activity row.
        attach_files(interaction, file_uuids, attrs["owner_user_uuid"])
        log_interaction("crm.interaction_logged", interaction)
        PubSub.broadcast_interaction(:interaction_created, interaction)
        ok

      other ->
        other
    end
  end

  # Best-effort: move the composer's staged files into the interaction's folder.
  defp attach_files(_interaction, [], _actor), do: :ok

  defp attach_files(%Interaction{} = interaction, file_uuids, actor_uuid) do
    case Attachments.ensure_interaction_folder(interaction.uuid, actor_uuid) do
      {:ok, folder_uuid} -> Enum.each(file_uuids, &Attachments.attach(&1, folder_uuid))
      _ -> :ok
    end
  end

  @spec update_interaction(Interaction.t(), map(), [map()] | nil, keyword()) ::
          {:ok, Interaction.t()} | {:error, Ecto.Changeset.t()}
  def update_interaction(%Interaction{} = interaction, attrs, party_inputs \\ nil, opts \\ []) do
    # Capture the OLD involved contacts before we replace parties / change the
    # subject, so anyone dropped by this edit still gets a refresh to remove it.
    old_uuids = PubSub.involved_contact_uuids(repo().preload(interaction, :parties))

    result =
      repo().transaction(fn ->
        case interaction |> Interaction.changeset(attrs) |> repo().update() do
          {:ok, updated} ->
            reconcile_parties(updated, party_inputs)
            repo().preload(updated, [:parties], force: true)

          {:error, changeset} ->
            repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, updated} = ok ->
        log_interaction("crm.interaction_updated", updated, opts)

        PubSub.broadcast_to_contacts(
          :interaction_updated,
          updated.uuid,
          old_uuids ++ PubSub.involved_contact_uuids(updated)
        )

        ok

      other ->
        other
    end
  end

  @spec delete_interaction(Interaction.t(), keyword()) ::
          {:ok, Interaction.t()} | {:error, Ecto.Changeset.t()}
  def delete_interaction(%Interaction{} = interaction, opts \\ []) do
    # Force parties loaded (works for any caller, not just the component path) so
    # every involved contact's feed is reached even though the row is now gone.
    interaction = repo().preload(interaction, :parties)

    case repo().delete(interaction) do
      {:ok, _deleted} = ok ->
        # Cascade the interaction's attachment folder (best-effort).
        Attachments.purge_interaction_media(interaction.uuid)
        log_interaction("crm.interaction_deleted", interaction, opts)
        PubSub.broadcast_interaction(:interaction_deleted, interaction)
        ok

      error ->
        error
    end
  end

  # The contact's Events feed audit entry for an interaction lifecycle event.
  # Logged in the context (not the LiveView) so it's written before the realtime
  # broadcast and so every path records it. The actor defaults to the interaction
  # owner; callers thread the acting user via `opts[:actor_uuid]`. Best-effort via
  # the Activity wrapper. Only the type + short subject are recorded (never the
  # free-text body).
  defp log_interaction(action, %Interaction{} = interaction, opts \\ []) do
    # No `target_uuid`: core treats it as the affected *user* and fans out a
    # notification, but an interaction isn't a user — setting it to the
    # interaction uuid just triggers a failed notification insert. The interaction
    # is referenced in metadata instead.
    Activity.log(action,
      actor_uuid: Keyword.get(opts, :actor_uuid) || interaction.owner_user_uuid,
      resource_type: "crm_contact",
      resource_uuid: interaction.contact_uuid,
      metadata: %{
        "interaction_uuid" => interaction.uuid,
        "interaction_type" => interaction.interaction_type,
        "subject" => interaction.subject
      }
    )
  end

  # ── Party reconciliation + snapshot ─────────────────────────────────

  # `nil` = the caller isn't touching parties (keep them as-is). An explicit list
  # (including `[]` to clear) reconciles them, preserving frozen snapshots.
  defp reconcile_parties(_interaction, nil), do: :ok

  defp reconcile_parties(interaction, party_inputs) when is_list(party_inputs),
    do: replace_parties(interaction, party_inputs)

  defp replace_parties(%Interaction{uuid: interaction_uuid}, party_inputs) do
    # Carry forward the snapshot frozen at log time for any party that's still
    # present, so editing an interaction doesn't silently rewrite a party's
    # profile to its *current* role/company. Only genuinely new parties get a
    # fresh snapshot. (Empty on create — nothing to preserve.)
    prior_snapshots =
      from(p in InteractionParty, where: p.interaction_uuid == ^interaction_uuid)
      |> repo().all()
      |> Map.new(&{party_identity(&1), &1.party_snapshot})

    from(p in InteractionParty, where: p.interaction_uuid == ^interaction_uuid)
    |> repo().delete_all()

    party_inputs
    |> Enum.reject(&blank_party?/1)
    |> Enum.with_index()
    |> Enum.each(fn {input, idx} ->
      snapshot = Map.get(prior_snapshots, input_identity(input)) || build_snapshot(input)

      changeset =
        InteractionParty.changeset(%InteractionParty{}, %{
          "interaction_uuid" => interaction_uuid,
          "raw_name" => party_raw_name(input),
          "contact_uuid" => input[:contact_uuid],
          "staff_person_uuid" => input[:staff_person_uuid],
          "party_snapshot" => snapshot,
          "position" => idx
        })

      # Inside a transaction — roll the whole interaction back on a bad party
      # (e.g. over-length free text) instead of raising out of the LiveView.
      case repo().insert(changeset) do
        {:ok, _party} -> :ok
        {:error, cs} -> repo().rollback(cs)
      end
    end)
  end

  # Stable identity of a party (resolved contact, resolved staff person, or its
  # free-text name) — used to match an edit's inputs back to the existing parties
  # so their frozen snapshots survive.
  defp party_identity(%InteractionParty{contact_uuid: c}) when is_binary(c), do: {:contact, c}
  defp party_identity(%InteractionParty{staff_person_uuid: s}) when is_binary(s), do: {:staff, s}
  defp party_identity(%InteractionParty{raw_name: n}), do: {:raw, n && String.trim(n)}

  defp input_identity(input) do
    cond do
      is_binary(input[:contact_uuid]) -> {:contact, input[:contact_uuid]}
      is_binary(input[:staff_person_uuid]) -> {:staff, input[:staff_person_uuid]}
      true -> {:raw, party_raw_name(input)}
    end
  end

  defp blank_party?(input), do: party_raw_name(input) in [nil, ""]

  defp party_raw_name(input), do: input[:raw_name] && String.trim(input[:raw_name])

  # Capture the party's profile "as it was then".
  defp build_snapshot(%{contact_uuid: contact_uuid}) when is_binary(contact_uuid) do
    case Contacts.get_contact(contact_uuid) do
      %Contact{} = contact -> contact_snapshot(contact)
      _ -> %{"source" => "crm_contact"}
    end
    |> stamp()
  end

  defp build_snapshot(%{staff_person_uuid: staff_uuid}) when is_binary(staff_uuid) do
    StaffLink.snapshot(staff_uuid) |> Map.put_new("source", "staff") |> stamp()
  end

  defp build_snapshot(_input), do: %{"source" => "free_text"} |> stamp()

  defp contact_snapshot(%Contact{} = contact) do
    membership = Contacts.primary_membership(contact)

    %{
      "source" => "crm_contact",
      "name" => Contact.display_name(contact),
      "company" => membership && membership.company && membership.company.name,
      "role_in_company" => membership && membership.role_in_company,
      "department" => membership && membership.department
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp stamp(map) do
    Map.put(
      map,
      "captured_at",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )
  end
end
