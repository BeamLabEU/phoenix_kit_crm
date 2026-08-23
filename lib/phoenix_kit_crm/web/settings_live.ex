defmodule PhoenixKitCRM.Web.SettingsLive do
  @moduledoc """
  CRM settings page — exposes the enable/disable toggle and role opt-in.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKit.Utils.Routes
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
       enabled_role_uuids: enabled_role_uuids
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
         |> push_navigate(to: Routes.path("/admin/settings/crm"))}

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
            <.checkbox
              :for={role <- @eligible_roles}
              name={"role_#{role.uuid}_enabled"}
              checked={MapSet.member?(@enabled_role_uuids, role.uuid)}
              label={role.name}
              phx-click="toggle_role"
              phx-value-role_uuid={role.uuid}
              phx-value-value={if MapSet.member?(@enabled_role_uuids, role.uuid), do: "false", else: "true"}
            >
              <:description :if={Map.get(role, :description)}>{role.description}</:description>
            </.checkbox>
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
end
