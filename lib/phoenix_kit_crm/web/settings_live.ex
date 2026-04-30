defmodule PhoenixKitCRM.Web.SettingsLive do
  @moduledoc """
  CRM settings page — exposes the enable/disable toggle, role opt-in, and
  Companies feature toggle.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKitCRM.RoleSettings

  @impl true
  def mount(_params, _session, socket) do
    eligible_roles = RoleSettings.list_eligible_roles()
    enabled_role_uuids = enabled_role_uuids()

    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "CRM settings"),
       enabled: PhoenixKitCRM.enabled?(),
       eligible_roles: eligible_roles,
       enabled_role_uuids: enabled_role_uuids,
       companies_enabled: Settings.get_boolean_setting("crm_companies_enabled", false)
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
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "CRM settings updated"))}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to update CRM settings")
         )}
    end
  end

  @impl true
  def handle_event("toggle_role", %{"role_uuid" => uuid, "value" => v}, socket) do
    enabled? = v == "on" or v == "true"

    case RoleSettings.set_enabled(uuid, enabled?) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:enabled_role_uuids, enabled_role_uuids())
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Role access updated"))}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to update role access")
         )}
    end
  end

  @impl true
  def handle_event("toggle_companies", %{"value" => v}, socket) do
    enabled? = v == "on" or v == "true"

    case Settings.update_boolean_setting_with_module(
           "crm_companies_enabled",
           enabled?,
           PhoenixKitCRM.module_key()
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           :companies_enabled,
           Settings.get_boolean_setting("crm_companies_enabled", false)
         )
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Companies setting updated"))}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to update Companies setting")
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl">
            <.icon name="hero-cog-6-tooth" class="w-6 h-6" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "CRM settings")}
          </h2>
          <p class="text-base-content/70 text-sm">
            {Gettext.gettext(
              PhoenixKitWeb.Gettext,
              "Module-specific configuration will appear here as the CRM grows."
            )}
          </p>

          <div class="divider"></div>

          <div class="flex items-center justify-between">
            <div>
              <div class="font-medium">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Enable CRM")}
              </div>
              <div class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitWeb.Gettext,
                  "Toggles this module on or off. Same setting as the admin Modules page."
                )}
              </div>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              phx-click="toggle"
              checked={@enabled}
            />
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-xl">
            <.icon name="hero-user-group" class="w-5 h-5" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Role Access")}
          </h2>
          <p class="text-base-content/70 text-sm">
            {Gettext.gettext(
              PhoenixKitWeb.Gettext,
              "Choose which roles can access the CRM module. Owner and Admin always have access."
            )}
          </p>

          <div class="divider"></div>

          <div class="flex flex-col gap-3">
            <div :if={@eligible_roles == []} class="text-base-content/50 text-sm">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "No eligible roles found.")}
            </div>
            <label
              :for={role <- @eligible_roles}
              class="flex items-center justify-between cursor-pointer"
            >
              <div>
                <div class="font-medium">{role.name}</div>
                <div :if={Map.get(role, :description)} class="text-xs text-base-content/60">
                  {role.description}
                </div>
              </div>
              <input
                type="checkbox"
                class="checkbox checkbox-primary"
                phx-click="toggle_role"
                phx-value-role_uuid={role.uuid}
                phx-value-value={if MapSet.member?(@enabled_role_uuids, role.uuid), do: "false", else: "true"}
                checked={MapSet.member?(@enabled_role_uuids, role.uuid)}
              />
            </label>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-xl">
            <.icon name="hero-building-office-2" class="w-5 h-5" />
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Features")}
          </h2>

          <div class="divider"></div>

          <div class="flex items-center justify-between">
            <div>
              <div class="font-medium">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Enable Companies")}
              </div>
              <div class="text-xs text-base-content/60">
                {Gettext.gettext(
                  PhoenixKitWeb.Gettext,
                  "Shows the Companies section in the CRM sidebar and navigation."
                )}
              </div>
            </div>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              phx-click="toggle_companies"
              phx-value-value={if @companies_enabled, do: "false", else: "true"}
              checked={@companies_enabled}
            />
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
