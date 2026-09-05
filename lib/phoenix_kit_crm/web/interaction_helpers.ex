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
  alias PhoenixKit.Utils.Date, as: DateUtils
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
  The viewer's timezone value — user profile → site `time_zone` setting →
  `"0"` — core's precedence (`PhoenixKit.Utils.Date.get_user_timezone/1`),
  written out because the page's user may be a partial map without the
  column. An IANA id (`Europe/Tallinn`) or a legacy fixed offset (`"2"`);
  never a number. One definition, so the same interaction shows the same
  time on every page that renders one.

  This used to be `Integer.parse/1` of that value, in hours: since core
  2.13.9 the value is an IANA id on any account that touched the picker,
  which parsed to 0 — every interaction rendered in UTC, the composer's
  "now" prefill was UTC, and a hand-typed local time was stored hours off.
  """
  @spec viewer_tz(map() | nil) :: String.t()
  def viewer_tz(%{} = user) do
    case Map.get(user, :user_timezone) do
      tz when is_binary(tz) and tz != "" -> tz
      _ -> site_tz()
    end
  end

  def viewer_tz(_), do: site_tz()

  # `Settings.get_setting/2` already answers the default when the database
  # is unreachable.
  defp site_tz, do: PhoenixKit.Settings.get_setting("time_zone", "0")

  @doc "A stored UTC datetime → display string in the viewer's timezone."
  @spec format_local(DateTime.t() | nil, String.t()) :: String.t()
  def format_local(nil, _tz), do: "—"

  def format_local(%DateTime{} = utc, tz) do
    utc |> DateUtils.shift_to_offset(tz) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  @doc """
  The viewer's current offset from UTC in minutes, for the composer's
  browser-side "this device is somewhere else" warning. A snapshot of NOW,
  which is the only instant that warning is about; storage never uses it.
  """
  @spec offset_minutes_now(String.t()) :: integer()
  def offset_minutes_now(tz) do
    now = DateTime.utc_now()
    local = now |> DateUtils.shift_to_offset(tz) |> DateTime.to_naive()
    NaiveDateTime.diff(local, DateTime.to_naive(now), :minute)
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
