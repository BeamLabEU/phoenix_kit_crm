defmodule PhoenixKitCRM.Web.SettingsLive do
  @moduledoc """
  CRM settings page — exposes the enable/disable toggle and role opt-in.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKitCRM.Paths
  alias PhoenixKitCRM.RoleSettings

  @impl true
  def mount(_params, _session, socket) do
    eligible_roles = RoleSettings.list_eligible_roles()
    enabled_role_uuids = enabled_role_uuids()

    {:ok,
     assign(socket,
       page_title: gettext("CRM settings"),
       enabled: PhoenixKitCRM.enabled?(),
       eligible_roles: eligible_roles,
       enabled_role_uuids: enabled_role_uuids,
       role_user_counts: role_user_counts()
     )}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    result =
      if socket.assigns.enabled,
        do: PhoenixKitCRM.disable_system(),
        else: PhoenixKitCRM.enable_system()

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:enabled, PhoenixKitCRM.enabled?())
         |> put_flash(:info, gettext("CRM settings updated"))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update CRM settings"))}
    end
  end

  @impl true
  def handle_event("toggle_role", %{"role_uuid" => uuid, "value" => v}, socket) do
    enabled? = v == "on" or v == "true"

    case RoleSettings.set_enabled(uuid, enabled?) do
      {:ok, _} ->
        # set_enabled/2 re-registers the role tabs in core's dashboard
        # registry, but the sidebar in this page's layout reads the registry
        # only when it renders, and none of its assigns change here — so the
        # new (or removed) subtab would not show until the operator navigated
        # away. The registry broadcasts badge updates only, never
        # (un)registrations, so a remount of this same page is the one lever
        # a module has; the flash survives it.
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role access updated"))
         |> push_navigate(to: Paths.settings())}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update role access"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl">
            <.icon name="hero-cog-6-tooth" class="w-6 h-6" />
            {gettext("General")}
          </h2>
          <p class="text-base-content/70 text-sm">
            {gettext("Module-specific configuration will appear here as the CRM grows.")}
          </p>

          <div class="divider"></div>

          <.checkbox
            name="crm_enabled"
            checked={@enabled}
            label={gettext("Enable CRM")}
            phx-click="toggle"
          >
            <:description>{gettext("Toggles this module on or off. Same setting as the admin Modules page.")}</:description>
          </.checkbox>
        </div>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-xl">
            <.icon name="hero-user-group" class="w-5 h-5" />
            {gettext("Role Access")}
          </h2>
          <p class="text-base-content/70 text-sm">
            {gettext("Choose which roles can access the CRM module. Owner and Admin always have access.")}
          </p>

          <div class="divider"></div>

          <div class="flex flex-col gap-3">
            <div :if={@eligible_roles == []} class="text-base-content/50 text-sm">
              {gettext("No eligible roles found.")}
            </div>
            <%!-- Enabled roles carry the portal info the overview used to
                 show — how many users hold the role, and the way into its
                 portal view. This page is where portal access lives now. --%>
            <div
              :for={role <- @eligible_roles}
              class="flex items-start justify-between gap-3 flex-wrap"
            >
              <.checkbox
                name={"role_#{role.uuid}_enabled"}
                checked={MapSet.member?(@enabled_role_uuids, role.uuid)}
                label={role.name}
                phx-click="toggle_role"
                phx-value-role_uuid={role.uuid}
                phx-value-value={if MapSet.member?(@enabled_role_uuids, role.uuid), do: "false", else: "true"}
              >
                <:description :if={Map.get(role, :description)}>{role.description}</:description>
              </.checkbox>
              <div
                :if={MapSet.member?(@enabled_role_uuids, role.uuid)}
                class="text-sm text-base-content/60 shrink-0"
              >
                {ngettext("%{count} user", "%{count} users",
                  Map.get(@role_user_counts, role.uuid, 0),
                  count: Map.get(@role_user_counts, role.uuid, 0)
                )}
                &middot;
                <.link navigate={Paths.role(role.uuid)} class="link link-hover">
                  {gettext("Open portal view")}
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>

    </div>
    """
  end

  defp enabled_role_uuids do
    RoleSettings.list_enabled()
    |> Enum.map(& &1.uuid)
    |> MapSet.new()
  end

  # Only enabled roles come back, which is all the template links to — a
  # disabled role has no portal view to open.
  defp role_user_counts do
    RoleSettings.list_enabled_with_user_counts()
    |> Map.new(&{&1.uuid, &1.count})
  end
end
