defmodule PhoenixKitCRM.Web.InteractionHelpers do
  @moduledoc """
  Shared render helpers for interaction timelines (contact + company feeds): the
  involved-party badge and its frozen-snapshot detail/title. A party that
  resolved to a CRM contact or a staff person links to that page; free-text
  parties render as a plain badge.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitCRM.Gettext

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
end
