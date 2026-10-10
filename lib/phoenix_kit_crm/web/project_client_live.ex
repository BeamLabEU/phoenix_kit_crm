defmodule PhoenixKitCRM.Web.ProjectClientLive do
  @moduledoc """
  The CRM **Client** tab for the `phoenix_kit_projects` hub — this module's
  `phoenix_kit_project_extensions/0` contribution (see that function in
  `PhoenixKitCRM`).

  Rendered by the projects hub via `live_render` with the hub's
  embed-session contract: `"project_uuid"` (the host project),
  `"config"` (this instance's config — `company_uuid` links the client),
  `"current_user_uuid"` / `"locale"`, `"can_write"` (the hub's verdict on
  the viewer for the extension's `log_interaction` action) and
  `"host_paths"` (where the hub's own pages are). Linkage is CONFIG-based —
  no FK, no dependency on the projects package; the admin picks the company
  in the project's Modules & features panel (a select over
  `PhoenixKitCRM.Companies.company_options/0`).

  Shows the linked company card and, once connected, the project's own
  interactions (`InteractionsComponent` in project mode, V8): the planned
  ones with "Log what happened", the feed, and — in a drawer this view
  owns, since core's drawer sends its close event to the view — the
  composer, opened by "Log an interaction", by "Log what happened" on a
  plan (the plan picked) or by Edit on a row. The two component instances
  talk to this view by message (`{:crm_client, …}`); a save closes the
  drawer and refreshes the feed. The dead render shows the company's
  recent interactions only.

  Off-router-mountable: no `handle_params/3` (the hub's hard requirement),
  so CRM reads run on the connected mount only.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  import PhoenixKitCRM.Web.InteractionHelpers, only: [viewer_tz: 1, current_user_name: 1]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Companies, Interactions, Paths, ProjectsLink}
  alias PhoenixKitCRM.PubSub, as: CRMPubSub
  alias PhoenixKitCRM.Schemas.{Company, Interaction}
  alias PhoenixKitCRM.Web.{InteractionsComponent, InteractionsDrawer}

  @recent_limit 5

  @impl true
  def mount(_params, session, socket) do
    maybe_put_locale(session)
    user = current_user(session)

    socket =
      assign(socket,
        project_uuid: session["project_uuid"],
        company_uuid: config_company_uuid(session),
        can_write: session["can_write"] == true,
        host_paths: session["host_paths"] || %{},
        current_user: user,
        current_user_uuid: user && user.uuid,
        current_user_name: current_user_name(%{phoenix_kit_current_user: user}),
        tz: viewer_tz(user),
        refresh_token: nil,
        connected: connected?(socket),
        company: nil,
        memberships: [],
        recent: [],
        loading: true
      )

    # The drawer (`InteractionsDrawer`): closed, and the feed it refreshes.
    socket = InteractionsDrawer.init(socket, feed_id(session["project_uuid"]))

    {:ok, if(connected?(socket), do: socket |> load() |> subscribe(), else: socket)}
  end

  defp config_company_uuid(session) do
    case get_in(session, ["config", "company_uuid"]) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  defp current_user(%{"current_user_uuid" => uuid}) when is_binary(uuid) and uuid != "" do
    safe(fn -> Auth.get_user(uuid) end)
  end

  defp current_user(_), do: nil

  defp load(%{assigns: %{company_uuid: nil}} = socket), do: assign(socket, loading: false)

  defp load(socket) do
    company = safe(fn -> Companies.get_company(socket.assigns.company_uuid) end)

    {memberships, recent} =
      if company do
        memberships = safe(fn -> Companies.list_memberships(company.uuid) end) || []

        # The connected render hands the feed to the component; the recent
        # list is the dead render's and a fallback, limited in SQL.
        recent =
          safe(fn -> Interactions.list_for_company(company.uuid, limit: @recent_limit) end) ||
            []

        recent = Enum.reject(recent, &Interaction.planned?/1)

        {memberships, recent}
      else
        {[], []}
      end

    assign(socket, company: company, memberships: memberships, recent: recent, loading: false)
  end

  # The feed is project-scoped, so its topic must cover every anchor,
  # including contacts and a former client. Calendar updates arrive on the
  # projects module's own PubSub server via the optional bridge.
  defp subscribe(socket) do
    if is_binary(socket.assigns.project_uuid) do
      safe(fn ->
        CRMPubSub.subscribe(CRMPubSub.topic_project_interactions(socket.assigns.project_uuid))
      end)

      ProjectsLink.subscribe_events(socket.assigns.project_uuid)
    end

    socket
  end

  @impl true
  # The button is only rendered with `can_write`, but the event is a message
  # anyone on the page can send: refuse it here as well.
  def handle_event("open_composer", _params, %{assigns: %{can_write: true}} = socket),
    do: {:noreply, InteractionsDrawer.open(socket)}

  def handle_event("open_composer", _params, socket), do: {:noreply, socket}

  def handle_event("close_composer", _params, socket),
    do: {:noreply, InteractionsDrawer.close(socket)}

  @impl true
  # The feed instance asks for the drawer (empty, a new plan, a row to
  # change), the composer instance says when it is done.
  def handle_info({:crm_client, _, _} = message, socket), do: drawer_info(message, socket)
  def handle_info({:crm_client, _} = message, socket), do: drawer_info(message, socket)

  # A meeting logged on the company from anywhere refreshes the feed here.
  def handle_info({:crm, _event, %{interaction_uuid: _}}, socket),
    do: {:noreply, refresh_feed(socket)}

  def handle_info({:projects, event, %{uuid: uuid}}, socket)
      when event in [:project_event_created, :project_event_updated, :project_event_deleted] do
    if uuid == socket.assigns.project_uuid do
      socket = refresh_feed(socket)

      if socket.assigns.composer do
        send_update(InteractionsComponent,
          id: InteractionsDrawer.composer_id(composer_id(uuid), socket.assigns.composer),
          refresh_token: socket.assigns.refresh_token
        )
      end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp drawer_info(message, socket) do
    case InteractionsDrawer.handle_info(message, socket, can_write: socket.assigns.can_write) do
      {:ok, socket} -> {:noreply, socket}
      :ignore -> {:noreply, socket}
    end
  end

  defp refresh_feed(socket), do: InteractionsDrawer.refresh_feed(socket)

  defp feed_id(project_uuid), do: "crm-project-interactions-#{project_uuid}"
  defp composer_id(project_uuid), do: "crm-project-composer-#{project_uuid}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= cond do %>
        <% @loading -> %>
          <div class="card border border-base-200 bg-base-100">
            <div class="card-body py-4">
              <div class="flex items-center gap-3">
                <div class="skeleton w-10 h-10 rounded-full shrink-0"></div>
                <div class="flex flex-col gap-2 grow">
                  <div class="skeleton h-4 w-40"></div>
                  <div class="skeleton h-3 w-24"></div>
                </div>
              </div>
            </div>
          </div>
        <% @company -> %>
          <div class="card border border-base-200 bg-base-100">
            <div class="card-body py-4 gap-2">
              <div class="flex items-center gap-3">
                <%!-- A plain centred disc: daisyUI 5 renamed `.avatar.placeholder`
                     and the initial sat in the corner of the circle. --%>
                <div class="bg-primary/10 text-primary rounded-full w-10 h-10 flex items-center justify-center shrink-0">
                  <span class="text-sm font-bold">{initial(@company.name)}</span>
                </div>
                <div class="min-w-0 grow">
                  <div class="flex items-center gap-2 min-w-0">
                    <h3 class="font-semibold truncate">{@company.name}</h3>
                    <%!-- The linkage is config-based, so trashing the company in
                         CRM can't unlink it here — say so instead of presenting a
                         soft-deleted company as the live client. --%>
                    <span :if={Company.trashed?(@company)} class="badge badge-warning badge-sm shrink-0">
                      {gettext("Trashed")}
                    </span>
                  </div>
                  <p class="text-xs opacity-60">
                    {ngettext("%{count} member contact", "%{count} member contacts", length(@memberships))}
                  </p>
                </div>
                <.button
                  :if={assigns[:connected] == true and @can_write}
                  type="button"
                  phx-click="open_composer"
                  class="btn-primary btn-sm"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Log an interaction")}
                </.button>
                <.link navigate={Paths.company(@company.uuid)} class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                  {gettext("Open in CRM")}
                </.link>
              </div>
            </div>
          </div>

          <%!-- Connected: the planned ones and the feed (project mode, no
               composer — that is the drawer's). --%>
          <.live_component
            :if={assigns[:connected] == true}
            module={InteractionsComponent}
            id={feed_id(@project_uuid)}
            company={@company}
            project_uuid={@project_uuid}
            host_paths={@host_paths}
            can_write={@can_write}
            show_composer={false}
            current_user_uuid={@current_user_uuid}
            current_user_name={@current_user_name}
            phoenix_kit_current_user={@current_user}
            tz={@tz}
            refresh_token={@refresh_token}
          />

          <%!-- The composer, in a drawer this view owns. --%>
          <InteractionsDrawer.drawer
            :if={assigns[:composer]}
            id={composer_id(@project_uuid)}
            composer={@composer}
            title={gettext("Log an interaction with %{name}", name: @company.name)}
            company={@company}
            project_uuid={@project_uuid}
            host_paths={@host_paths}
            can_write={@can_write}
            current_user_uuid={@current_user_uuid}
            current_user_name={@current_user_name}
            phoenix_kit_current_user={@current_user}
            tz={@tz}
          />

          <div :if={assigns[:connected] != true and @recent != []} class="card border border-base-200 bg-base-100">
            <div class="card-body py-4 gap-2">
              <h4 class="text-sm font-semibold opacity-70">{gettext("Recent interactions")}</h4>
              <div class="divide-y divide-base-200">
                <div :for={interaction <- @recent} class="py-2 flex items-baseline gap-2 text-sm">
                  <span class="badge badge-ghost badge-xs shrink-0">
                    {Interaction.type_label(interaction.interaction_type)}
                  </span>
                  <span class="truncate min-w-0">
                    {interaction.subject || gettext("(no subject)")}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <div :if={assigns[:connected] != true and @recent == []} class="text-sm opacity-60">
            {gettext("No interactions with this client yet.")}
          </div>
        <% true -> %>
          <div class="card border border-dashed border-base-300 bg-base-100">
            <div class="card-body items-center text-center py-8 gap-2">
              <p class="text-sm opacity-70">
                {gettext("Client not set.")}
              </p>
              <p class="text-xs opacity-50">
                {gettext("Pick the client company in the project's Modules & features panel.")}
              </p>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp initial(name) when is_binary(name) do
    case String.first(String.trim(name)) do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp initial(_), do: "?"

  defp maybe_put_locale(%{"locale" => locale}) when is_binary(locale) and locale != "" do
    Gettext.put_locale(PhoenixKitCRM.Gettext, locale)
  rescue
    _ -> :ok
  end

  defp maybe_put_locale(_), do: :ok

  # A CRM DB hiccup degrades the tab to its empty state — a contributed
  # extension tab must never crash the host project page.
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
