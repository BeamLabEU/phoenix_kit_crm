defmodule PhoenixKitCRM.Web.CRMLive do
  @moduledoc """
  Main admin LiveView for the CRM module — empty placeholder page.

  PhoenixKit wraps this in the admin layout automatically (sidebar, header,
  theme) thanks to the `live_view` field on `admin_tabs/0`.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.{Paths, RoleSettings}

  @impl true
  def mount(_params, _session, socket) do
    enabled = PhoenixKitCRM.enabled?()

    role_stats =
      if enabled do
        for role <- RoleSettings.list_enabled() do
          %{
            uuid: role.uuid,
            name: role.name,
            count: Roles.count_users_with_role(role.name)
          }
        end
      else
        []
      end

    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "CRM"),
       enabled: enabled,
       role_stats: role_stats
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

      <div :if={@enabled}>
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-lg font-semibold">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Enabled roles")}
          </h3>
          <span class="text-sm text-base-content/60">
            {Gettext.dngettext(
              PhoenixKitWeb.Gettext,
              "default",
              "%{count} role",
              "%{count} roles",
              length(@role_stats),
              count: length(@role_stats)
            )}
          </span>
        </div>

        <div :if={@role_stats == []} class="card bg-base-100 shadow-sm">
          <div class="card-body items-center text-center py-8 text-base-content/60">
            <.icon name="hero-user-group" class="w-8 h-8" />
            <p class="text-sm">
              {Gettext.gettext(
                PhoenixKitWeb.Gettext,
                "No roles connected to CRM yet. Enable a role in CRM settings."
              )}
            </p>
          </div>
        </div>

        <div
          :if={@role_stats != []}
          class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4"
        >
          <.link
            :for={stat <- @role_stats}
            navigate={Paths.role(stat.uuid)}
            class="card bg-base-100 shadow-sm hover:shadow-md transition-shadow border border-base-200 hover:border-primary"
          >
            <div class="card-body p-4">
              <div class="flex items-center justify-between gap-3">
                <div class="flex items-center gap-3 min-w-0">
                  <div class="avatar placeholder">
                    <div class="bg-primary/10 text-primary rounded-full w-10 h-10 grid place-items-center">
                      <.icon name="hero-user-group" class="w-5 h-5" />
                    </div>
                  </div>
                  <div class="min-w-0">
                    <div class="font-semibold truncate">{stat.name}</div>
                    <div class="text-xs text-base-content/60">
                      {Gettext.dngettext(
                        PhoenixKitWeb.Gettext,
                        "default",
                        "%{count} user",
                        "%{count} users",
                        stat.count,
                        count: stat.count
                      )}
                    </div>
                  </div>
                </div>
                <div class="badge badge-primary badge-lg font-semibold">{stat.count}</div>
              </div>
            </div>
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
