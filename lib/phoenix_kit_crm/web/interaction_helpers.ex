defmodule PhoenixKitCRM.Web.InteractionHelpers do
  @moduledoc """
  Shared render helpers for interaction timelines (contact + company feeds): the
  involved-party badge and its frozen-snapshot detail/title. A party that
  resolved to a CRM contact or a staff person links to that page; free-text
  parties render as a plain badge.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{Paths, StaffLink}

  @doc "An involved-party badge — links to the contact/staff page when resolvable."
  attr(:party, :map, required: true)

  def party_badge(assigns) do
    assigns = assign(assigns, :link, party_link(assigns.party))

    ~H"""
    <.link
      :if={@link}
      navigate={@link}
      class="badge badge-outline badge-sm gap-1 hover:badge-primary"
      title={snapshot_title(@party.party_snapshot)}
    >
      {@party.raw_name}<span :if={snapshot_detail(@party.party_snapshot)} class="opacity-60">— {snapshot_detail(@party.party_snapshot)}</span>
    </.link>
    <span
      :if={!@link}
      class="badge badge-outline badge-sm gap-1"
      title={snapshot_title(@party.party_snapshot)}
    >
      {@party.raw_name}<span :if={snapshot_detail(@party.party_snapshot)} class="opacity-60">— {snapshot_detail(@party.party_snapshot)}</span>
    </span>
    """
  end

  @doc "Page link for a party — CRM contact, then staff person, else nil (free text)."
  @spec party_link(map()) :: String.t() | nil
  def party_link(%{contact_uuid: cu}) when is_binary(cu), do: Paths.contact(cu)
  def party_link(%{staff_person_uuid: su}) when is_binary(su), do: StaffLink.person_path(su)
  def party_link(_), do: nil

  @doc ~S(An "Intern at Acme"-style detail from the frozen party snapshot.)
  @spec snapshot_detail(map() | nil) :: String.t() | nil
  def snapshot_detail(snapshot) when is_map(snapshot) do
    role = snapshot["role_in_company"] || snapshot["job_title"]
    company = snapshot["company"]

    cond do
      role && company -> "#{role}, #{company}"
      role -> role
      company -> company
      true -> nil
    end
  end

  def snapshot_detail(_), do: nil

  @doc "Tooltip noting when the snapshot was captured, or nil."
  @spec snapshot_title(map() | nil) :: String.t() | nil
  def snapshot_title(snapshot) when is_map(snapshot) do
    case snapshot["captured_at"] do
      ts when is_binary(ts) -> gettext("Captured %{ts}", ts: ts)
      _ -> nil
    end
  end

  def snapshot_title(_), do: nil

  @doc """
  The viewer's timezone offset in hours — user profile → system setting → UTC,
  via core's `PhoenixKit.Utils.Date.get_user_timezone/1` (which stores offset
  strings like `"0"` / `"+5"`). One definition, so the same interaction shows
  the same time on every page that renders one — this used to live as three
  private copies across the show LiveViews and the overview.
  """
  @spec tz_offset(map() | nil) :: integer()
  def tz_offset(%{} = user) do
    case PhoenixKit.Utils.Date.get_user_timezone(user) do
      off when is_binary(off) ->
        case Integer.parse(off) do
          {hours, _} -> hours
          _ -> 0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  def tz_offset(_), do: 0

  @doc "A stored UTC datetime → display string in the viewer's timezone."
  @spec format_local(DateTime.t() | nil, integer()) :: String.t()
  def format_local(nil, _offset), do: "—"

  def format_local(%DateTime{} = utc, offset) do
    utc |> DateTime.add(offset * 3600, :second) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  @doc """
  The acting user's uuid from the page assigns — what the composer stamps as
  the interaction owner. One definition for both show LiveViews (they were
  verbatim copies).
  """
  @spec current_user_uuid(map()) :: binary() | nil
  def current_user_uuid(assigns) do
    case assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  @doc "Display name for the composer's \"Add me\" shortcut — full name, else email."
  @spec current_user_name(map()) :: String.t() | nil
  def current_user_name(assigns) do
    case assigns[:phoenix_kit_current_user] do
      %{} = user ->
        case User.full_name(user) do
          name when is_binary(name) and name != "" -> name
          _ -> user.email
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
