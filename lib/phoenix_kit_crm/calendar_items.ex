defmodule PhoenixKitCRM.CalendarItems do
  @moduledoc """
  The CRM's interactions as calendar items — read-only, for the two
  calendars that are not the CRM's: a project's Calendar tab (the Client
  extension's `calendar:` in `phoenix_kit_project_extensions/0`) and a
  person's own calendar (`phoenix_kit_calendar_sources/0`). Neither module
  is a dependency; both reach this one by name and get plain maps back.

  Nothing is copied anywhere: an item is the interaction as it is now, so a
  plan that moves or is cancelled is right the next time a calendar looks.

  ## An item

      %{
        source: "crm",            # with `id`, the item's identity
        id: "<interaction uuid>",
        title: "Site visit",      # the subject, else "Meeting — Acme"
        label: "Meeting",         # the kind, for a chip
        starts_at: ~U[...],       # UTC
        ends_at: ~U[...] | nil,   # nil when nobody said how long
        all_day: false,
        status: "planned",        # planned | happened | cancelled
        location: "…" | nil,
        url: "/admin/crm/…?tab=interactions",   # the only way to change it
        updated_at: ~U[...]
      }

  Both lists answer `%{items: [item], truncated: boolean}`: at most
  `#{200}` items, soonest first, each overlapping `[from, until)`.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.Paths
  alias PhoenixKitCRM.Schemas.{Company, Contact, Interaction, InteractionParty}

  @source "crm"
  @cap 200

  @type item :: %{
          source: String.t(),
          id: String.t(),
          title: String.t(),
          label: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t() | nil,
          all_day: false,
          status: String.t(),
          location: String.t() | nil,
          url: String.t(),
          updated_at: DateTime.t() | nil
        }

  @type result :: %{items: [item()], truncated: boolean()}

  @doc "The source key the items carry."
  @spec source() :: String.t()
  def source, do: @source

  @doc """
  A project's interactions — planned, happened and cancelled — in the
  window. What the projects hub shows on the project's Calendar tab.
  """
  @spec for_project(binary(), DateTime.t(), DateTime.t()) :: result()
  def for_project(project_uuid, %DateTime{} = from, %DateTime{} = until) do
    case Ecto.UUID.cast(project_uuid) do
      {:ok, _} ->
        Interaction
        |> where([i], i.project_uuid == ^project_uuid)
        |> in_window(from, until)
        |> items()

      :error ->
        empty()
    end
  rescue
    _ -> empty()
  catch
    :exit, _ -> empty()
  end

  def for_project(_project_uuid, _from, _until), do: empty()

  @doc """
  The interactions a user is in — as the one who wrote it, or as a party
  through their staff record or their contact — in the window. What a
  person's own calendar shows. The check is the list itself: nobody is
  handed an interaction they are not part of.
  """
  @spec for_user(binary(), DateTime.t(), DateTime.t()) :: result()
  def for_user(user_uuid, %DateTime{} = from, %DateTime{} = until) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, _} ->
        Interaction
        |> where(
          [i],
          i.owner_user_uuid == ^user_uuid or i.uuid in subquery(party_of(user_uuid))
        )
        |> in_window(from, until)
        |> items()

      :error ->
        empty()
    end
  rescue
    _ -> empty()
  catch
    :exit, _ -> empty()
  end

  def for_user(_user_uuid, _from, _until), do: empty()

  # The interactions that name the user as a party: by their contact, or by
  # their staff record (another module's table, read schemaless — it exists
  # in every install, and is simply empty without the staff module).
  defp party_of(user_uuid) do
    contacts = from(c in Contact, where: c.user_uuid == ^user_uuid, select: c.uuid)

    staff =
      from(s in "phoenix_kit_staff_people",
        where: s.user_uuid == type(^user_uuid, UUIDv7),
        select: type(s.uuid, UUIDv7)
      )

    from(p in InteractionParty,
      where: p.contact_uuid in subquery(contacts) or p.staff_person_uuid in subquery(staff),
      select: p.interaction_uuid
    )
  end

  # Overlap with `[from, until)`: it starts before the window ends, and it
  # ends (or, with no length, starts) at or after the window begins. A row
  # is at most a day long, so one day of slack on the start is enough for
  # SQL. The exact overlap must also be checked before capping the rows.
  defp in_window(query, from, until) do
    earliest = DateTime.add(from, -86_400, :second)

    query
    |> where([i], i.occurred_at >= ^earliest and i.occurred_at < ^until)
    |> where(
      [i],
      fragment("? + COALESCE(?, 0) * INTERVAL '1 minute'", i.occurred_at, i.duration_minutes) >=
        ^from
    )
    |> join(:left, [i], c in Contact, on: c.uuid == i.contact_uuid)
    |> join(:left, [i, c], co in Company, on: co.uuid == i.company_uuid)
    |> where(
      [i, c, co],
      (not is_nil(i.contact_uuid) and c.status != "trashed") or
        (not is_nil(i.company_uuid) and co.status != "trashed")
    )
    |> order_by([i], asc: i.occurred_at, asc: i.inserted_at, asc: i.uuid)
    |> limit(^(@cap + 1))
  end

  defp items(query) do
    rows =
      query
      |> RepoHelper.repo().all()
      |> RepoHelper.repo().preload([:contact, :company])

    %{items: rows |> Enum.take(@cap) |> Enum.map(&item/1), truncated: length(rows) > @cap}
  end

  defp empty, do: %{items: [], truncated: false}

  @doc "One interaction as a calendar item. Needs the anchor preloaded."
  @spec item(Interaction.t()) :: item()
  def item(%Interaction{} = i) do
    label = Interaction.type_label(i.interaction_type)

    %{
      source: @source,
      id: i.uuid,
      title: title(i, label),
      label: label,
      starts_at: i.occurred_at,
      ends_at: Interaction.ended_at(i),
      all_day: false,
      status: i.status,
      location: i.location,
      url: anchor_path(i) <> "?tab=interactions",
      updated_at: i.updated_at
    }
  end

  defp title(%Interaction{subject: subject}, _label) when is_binary(subject) and subject != "",
    do: subject

  defp title(i, label) do
    case anchor_name(i) do
      nil -> label
      name -> "#{label} — #{name}"
    end
  end

  defp anchor_name(%Interaction{company: %Company{} = c}), do: Company.display_name(c)
  defp anchor_name(%Interaction{contact: %Contact{} = c}), do: Contact.display_name(c)
  defp anchor_name(_), do: nil

  defp anchor_path(%Interaction{company_uuid: uuid}) when is_binary(uuid), do: Paths.company(uuid)
  defp anchor_path(%Interaction{contact_uuid: uuid}) when is_binary(uuid), do: Paths.contact(uuid)
  defp anchor_path(_), do: Paths.index()
end
