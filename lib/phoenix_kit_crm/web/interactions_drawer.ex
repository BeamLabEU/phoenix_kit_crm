defmodule PhoenixKitCRM.Web.InteractionsDrawer do
  @moduledoc """
  The composer drawer every interactions page shares: the feed (with what
  is planned) stays on the page, and the composer opens in a drawer the
  host LiveView owns — core's drawer sends its close event to the view, so
  a LiveComponent cannot own one.

  A host:

    * calls `init/2` in mount with the feed instance's id;
    * renders the feed instance with `show_composer={false}` and
      `<.drawer composer={@composer} … />` next to it;
    * forwards `{:crm_client, _, _}` / `{:crm_client, _}` messages to
      `handle_info/2` and the `"close_composer"` event to `close/1`.

  The two `InteractionsComponent` instances never talk to each other: the
  feed asks the host to open the drawer (`{:crm_client, :compose, opts}`),
  the composer tells it when it is done. Each open is a fresh composer
  instance (a token in its id), so an edit or a plan is applied on mount
  and nothing leaks between opens.
  """
  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitCRM.Gettext

  import Phoenix.LiveView, only: [send_update: 2]

  alias PhoenixKitCRM.Web.InteractionsComponent

  @doc "The drawer's state on the host: closed, and which feed to refresh after a save."
  @spec init(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def init(socket, feed_id \\ nil),
    do: Phoenix.Component.assign(socket, composer: nil, composer_feed_id: feed_id)

  @doc """
  Opens the drawer. `opts`: `:editing_uuid` (the row to change) and
  `:status` (`"planned"` for a new plan; the outcome an existing plan is
  opened to record).
  """
  @spec open(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def open(socket, opts \\ []) do
    Phoenix.Component.assign(socket,
      composer: %{
        editing_uuid: opts[:editing_uuid],
        status: opts[:status],
        token: System.unique_integer([:positive])
      }
    )
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket), do: Phoenix.Component.assign(socket, composer: nil)

  @doc """
  The messages the two instances send the host. Returns `{:ok, socket}`
  when the message was the drawer's, `:ignore` otherwise. A host that may
  not write passes `can_write: false` and the request to open is dropped —
  the button is not drawn for it, but a message is only a message.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t(), keyword()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | :ignore
  def handle_info(message, socket, opts \\ [])

  def handle_info({:crm_client, :compose, compose_opts}, socket, opts) do
    if Keyword.get(opts, :can_write, true),
      do: {:ok, open(socket, compose_opts)},
      else: {:ok, socket}
  end

  def handle_info({:crm_client, :saved}, socket, _opts),
    do: {:ok, socket |> close() |> refresh_feed()}

  def handle_info({:crm_client, :cancel}, socket, _opts), do: {:ok, close(socket)}
  def handle_info(_message, _socket, _opts), do: :ignore

  @doc "Has the feed instance reload (a fresh token is what its `update/2` reloads on)."
  @spec refresh_feed(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_feed(%{assigns: %{composer_feed_id: id}} = socket) when is_binary(id) do
    token = System.unique_integer([:positive])
    send_update(InteractionsComponent, id: id, refresh_token: token)
    Phoenix.Component.assign(socket, :refresh_token, token)
  end

  def refresh_feed(socket), do: socket

  @doc "The composer instance's id for an open drawer."
  @spec composer_id(String.t(), map()) :: String.t()
  def composer_id(id, %{token: token}), do: "#{id}-#{token}"

  attr(:id, :string, required: true)
  attr(:composer, :map, default: nil)
  attr(:title, :string, required: true)
  attr(:contact, :any, default: nil)
  attr(:company, :any, default: nil)
  attr(:project_uuid, :string, default: nil)
  attr(:host_paths, :map, default: %{})
  attr(:can_write, :boolean, default: true)
  attr(:current_user_uuid, :string, default: nil)
  attr(:current_user_name, :string, default: nil)
  attr(:phoenix_kit_current_user, :any, default: nil)
  attr(:tz, :string, default: "0")

  def drawer(assigns) do
    ~H"""
    <.modal
      :if={@composer}
      show
      on_close="close_composer"
      id={@id}
      aria-label={gettext("Log an interaction")}
      placement={:end}
      max_width="lg"
    >
      <:title>{drawer_title(@composer, @title)}</:title>
      <.live_component
        module={InteractionsComponent}
        id={composer_id(@id, @composer)}
        contact={@contact}
        company={@company}
        project_uuid={@project_uuid}
        host_paths={@host_paths}
        can_write={@can_write}
        show_feed={false}
        open_editing_uuid={@composer.editing_uuid}
        open_status={@composer.status}
        current_user_uuid={@current_user_uuid}
        current_user_name={@current_user_name}
        phoenix_kit_current_user={@phoenix_kit_current_user}
        tz={@tz}
      />
    </.modal>
    """
  end

  defp drawer_title(%{editing_uuid: uuid, status: "happened"}, _title) when is_binary(uuid),
    do: gettext("Log what happened")

  defp drawer_title(%{editing_uuid: uuid, status: "cancelled"}, _title) when is_binary(uuid),
    do: gettext("It was cancelled")

  defp drawer_title(%{editing_uuid: uuid}, _title) when is_binary(uuid),
    do: gettext("Edit interaction")

  defp drawer_title(%{status: "planned"}, _title), do: gettext("Plan ahead")
  defp drawer_title(_composer, title), do: title
end
