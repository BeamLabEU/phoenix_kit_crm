defmodule PhoenixKitCRM.Web.CRMLive do
  @moduledoc """
  Main admin LiveView for the CRM module — empty placeholder page.

  PhoenixKit wraps this in the admin layout automatically (sidebar, header,
  theme) thanks to the `live_view` field on `admin_tabs/0`.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKitCRM.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "CRM"),
       enabled: PhoenixKitCRM.enabled?()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-3xl px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body items-center text-center">
          <h2 class="card-title text-3xl">CRM</h2>
          <p class="text-base-content/70 mt-1">
            {Gettext.gettext(
              PhoenixKitWeb.Gettext,
              "This is a placeholder. CRM functionality will live here."
            )}
          </p>

          <div class="flex flex-wrap justify-center gap-2 mt-4">
            <div class={[
              "badge gap-1",
              if(@enabled, do: "badge-success", else: "badge-ghost")
            ]}>
              <.icon
                name={if @enabled, do: "hero-check-circle-mini", else: "hero-minus-circle-mini"}
                class="w-3 h-3"
              />
              {if @enabled, do: "Enabled", else: "Disabled"}
            </div>
          </div>

          <div class="mt-4">
            <.link navigate={Paths.settings()} class="btn btn-outline btn-sm">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
              {Gettext.gettext(PhoenixKitWeb.Gettext, "CRM settings")}
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
