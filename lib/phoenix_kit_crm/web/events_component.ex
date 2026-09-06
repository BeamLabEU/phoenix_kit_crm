defmodule PhoenixKitCRM.Web.EventsComponent do
  @moduledoc """
  The **Events** tab for a CRM record — a read-only, paginated feed of the
  `PhoenixKit.Activity` entries scoped to it (`resource_type` + `resource_uuid`).
  Parameterized by `:resource_type` (`"crm_contact"` / `"crm_company"`) and
  `:resource_uuid`, so it serves both the contact and company profiles.

  Labels/icons come from `PhoenixKitCRM.ActivityLabels`; the badge colour reuses
  core `PhoenixKit.Activity.action_badge_color/1`. Absolute timestamps render in
  the viewer's timezone (the `tz` assign — an IANA id or a legacy offset).
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitCRM.Gettext

  import PhoenixKitCRM.Web.InteractionHelpers, only: [format_local: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCRM.{ActivityLabels, Paths}

  @per_page 20

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign_new(:page, fn -> 1 end)
     |> assign_new(:tz, fn -> "0" end)
     |> load_events()}
  end

  @impl true
  def handle_event("events_page", %{"page" => page}, socket) do
    page =
      case Integer.parse(to_string(page)) do
        {n, _} when n >= 1 -> n
        _ -> 1
      end

    {:noreply, socket |> assign(:page, page) |> load_events()}
  end

  # Scope to THIS record via core's filters (`resource_type` + `resource_uuid`),
  # offset-paginated. Rescued so a transient query error renders an empty feed
  # rather than crashing the tab.
  defp load_events(socket) do
    result =
      safe_list(
        resource_type: socket.assigns.resource_type,
        resource_uuid: socket.assigns.resource_uuid,
        page: socket.assigns.page,
        per_page: @per_page,
        preload: [:actor]
      )

    assign(socket,
      events: result.entries,
      total: result.total,
      total_pages: result.total_pages
    )
  end

  defp safe_list(opts) do
    Activity.list(opts)
  rescue
    _ -> %{entries: [], total: 0, total_pages: 1}
  end

  defp actor_label(%{actor: %{email: email}}) when is_binary(email), do: email
  defp actor_label(_), do: gettext("System")

  # Link the actor to their user page when known (else plain "System").
  defp actor_path(%{actor_uuid: uuid, actor: %{email: email}})
       when is_binary(uuid) and uuid != "" and is_binary(email),
       do: Paths.user_view(uuid)

  defp actor_path(_), do: nil

  attr(:entry, :map, required: true)

  defp actor_name(assigns) do
    assigns = assign(assigns, :path, actor_path(assigns.entry))

    ~H"""
    <.link :if={@path} navigate={@path} class="link link-hover">{actor_label(@entry)}</.link><span :if={!@path}>{actor_label(@entry)}</span>
    """
  end

  # Deep link to the core admin Activity viewer, scoped to this record.
  defp activity_log_path(resource_type, resource_uuid) do
    query =
      URI.encode_query(%{"resource_type" => resource_type, "resource_uuid" => resource_uuid})

    Routes.path("/admin/activity?#{query}")
  end

  defp format_at(%DateTime{} = dt, tz) when is_binary(tz), do: format_local(dt, tz)
  defp format_at(_, _), do: ""

  # Friendly "2 hours ago"; the absolute timestamp stays on the row title.
  defp relative_time(%DateTime{} = dt, tz) do
    case DateTime.diff(DateTime.utc_now(), dt, :second) do
      d when d < 45 ->
        gettext("just now")

      d when d < 3600 ->
        ngettext("%{count} minute ago", "%{count} minutes ago", max(div(d, 60), 1))

      d when d < 86_400 ->
        ngettext("%{count} hour ago", "%{count} hours ago", div(d, 3600))

      d when d < 2_592_000 ->
        ngettext("%{count} day ago", "%{count} days ago", div(d, 86_400))

      _ ->
        format_at(dt, tz)
    end
  end

  defp relative_time(_, _), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <div class="flex items-center justify-between gap-2">
          <h2 class="card-title text-lg">
            <.icon name="hero-clock" class="w-5 h-5" /> {gettext("Events")} ({@total})
          </h2>
          <.link
            navigate={activity_log_path(@resource_type, @resource_uuid)}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Open in Activity log")}
            <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
          </.link>
        </div>

        <.empty_state
          :if={@events == []}
          icon="hero-clock"
          title={gettext("No activity recorded yet.")}
        />

        <ul :if={@events != []} class="flex flex-col divide-y divide-base-200">
          <li :for={e <- @events} class="flex items-start gap-3 py-2.5">
            <% {icon, label} = ActivityLabels.describe(e.action, e.metadata || %{}) %>
            <% detail = ActivityLabels.detail(e.action, e.metadata || %{}) %>
            <span class={"badge badge-sm shrink-0 mt-0.5 #{Activity.action_badge_color(e.action)}"}>
              <.icon name={icon} class="w-3.5 h-3.5" />
            </span>
            <div class="flex-1 min-w-0">
              <div class="text-sm">
                <span class="font-medium">{label}</span>
                <span :if={detail} class="text-base-content/60">— {detail}</span>
              </div>
              <div class="text-xs text-base-content/50" title={format_at(e.inserted_at, @tz)}>
                <.actor_name entry={e} /> · {relative_time(e.inserted_at, @tz)}
              </div>
            </div>
          </li>
        </ul>

        <div :if={@total_pages > 1} class="flex items-center justify-between gap-2 pt-3">
          <button
            type="button"
            phx-target={@myself}
            phx-click="events_page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" /> {gettext("Previous")}
          </button>
          <span class="text-xs text-base-content/60">
            {gettext("Page %{page} of %{total}", page: @page, total: @total_pages)}
          </span>
          <button
            type="button"
            phx-target={@myself}
            phx-click="events_page"
            phx-value-page={@page + 1}
            disabled={@page >= @total_pages}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Next")} <.icon name="hero-chevron-right" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end
end
