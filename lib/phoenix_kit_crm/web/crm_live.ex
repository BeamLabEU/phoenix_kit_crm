defmodule PhoenixKitCRM.Web.CRMLive do
  @moduledoc """
  Main admin LiveView for the CRM module — the module's landing page.

  Shows what the CRM actually holds (companies, contacts, interactions, lists),
  each count linking to the page that manages it, plus the PhoenixKit roles that
  have CRM access.

  A note on what is deliberately NOT here: the product review asked for a
  coverage card reading "N of M order customers have no CRM contact". That number
  cannot be computed here. Orders live in the host application's own tables, and
  this package must not reach into them — the same boundary that put the backfill
  mix task in the host rather than in this module. So when there are no contacts
  yet, the page names the backfill task instead of inventing a denominator it
  cannot honestly compute.

  PhoenixKit wraps this in the admin layout automatically (sidebar, header,
  theme) thanks to the `live_view` field on `admin_tabs/0`.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKitCRM.{Companies, Contacts, Interactions, Lists, Paths, RoleSettings}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("CRM"),
       page_subtitle:
         gettext(
           "Customer relationship management — companies, contacts and the roles that can reach them"
         ),
       enabled: PhoenixKitCRM.enabled?(),
       role_stats: [],
       counts: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # Counts and role stats are DB reads, so they wait for the connected mount —
    # the dead render would pay for them and then throw the result away.
    if connected?(socket) and socket.assigns.enabled do
      {:noreply,
       socket
       |> assign(:role_stats, RoleSettings.list_enabled_with_user_counts())
       |> assign(:counts, load_counts())}
    else
      {:noreply, socket}
    end
  end

  # Every count must match what the page it links to actually shows, or the
  # card is a lie the user discovers one click later: companies/contacts
  # exclude trashed rows (their lists' default scope) and lists count only
  # active ones (the Lists page opens on the Active tab). Interactions have no
  # status, so the total is the total.
  defp load_counts do
    %{
      companies: Companies.count_companies(),
      contacts: Contacts.count_contacts(),
      interactions: Interactions.count_interactions(),
      lists: Lists.count_lists(status: "active")
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <div :if={!@enabled} class="alert alert-warning">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <div>
          <div class="font-semibold">{gettext("CRM is disabled")}</div>
          <div class="text-sm">
            {gettext("Enable it in CRM settings to start recording companies and contacts.")}
          </div>
        </div>
        <.link navigate={Paths.settings()} class="btn btn-sm">
          {gettext("CRM settings")}
        </.link>
      </div>

      <%!-- Honest counts. Each one links to the page that manages it, so a zero
           is a way in rather than a dead end. --%>
      <div :if={@enabled} class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <.count_card
          label={gettext("Companies")}
          count={@counts && @counts.companies}
          icon="hero-building-office-2"
          navigate={Paths.companies()}
        />
        <.count_card
          label={gettext("Contacts")}
          count={@counts && @counts.contacts}
          icon="hero-user-circle"
          navigate={Paths.contacts()}
        />
        <.count_card
          label={gettext("Interactions")}
          count={@counts && @counts.interactions}
          icon="hero-chat-bubble-left-right"
          navigate={Paths.contacts()}
        />
        <.count_card
          label={gettext("Lists")}
          count={@counts && @counts.lists}
          icon="hero-queue-list"
          navigate={Paths.lists()}
        />
      </div>

      <%!-- Shown only while the CRM is genuinely empty. The routes offered here
           are this package's own — naming a specific host application's
           backfill task would break the same boundary the moduledoc above
           relies on, and would print a command that does not exist in any
           other consumer. A host that ships an importer documents it itself. --%>
      <div
        :if={@enabled && @counts && @counts.contacts == 0}
        class="card bg-base-100 shadow-sm border border-base-200"
      >
        <div class="card-body gap-2">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-arrow-down-tray" class="w-5 h-5 text-primary" />
            {gettext("No contacts yet")}
          </h3>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Add a contact by hand, or paste/upload a batch of them into a contact list."
            )}
          </p>
          <div class="flex flex-wrap gap-2">
            <.link navigate={Paths.contact_new()} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New contact")}
            </.link>
            <.link navigate={Paths.lists()} class="btn btn-outline btn-sm">
              <.icon name="hero-queue-list" class="w-4 h-4" /> {gettext("Import into a list")}
            </.link>
          </div>
        </div>
      </div>

      <div :if={@enabled}>
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-lg font-semibold">
            {gettext("Portal access")}
          </h3>
          <span class="text-sm text-base-content/60">
            {ngettext("%{count} role", "%{count} roles", length(@role_stats),
              count: length(@role_stats)
            )}
          </span>
        </div>
        <%!-- These are PhoenixKit RBAC roles and their user counts — who may open
             the CRM — not CRM records. The heading says so, because read as CRM
             data they are badly misleading. --%>
        <p class="text-sm text-base-content/60 mb-3">
          {gettext("PhoenixKit roles allowed to open the CRM, and how many users hold each.")}
        </p>

        <.empty_state
          :if={@role_stats == []}
          icon="hero-user-group"
          title={gettext("No roles connected to CRM yet. Enable a role in CRM settings.")}
          variant="card"
        />

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
                      {ngettext("%{count} user", "%{count} users", stat.count, count: stat.count)}
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

  attr(:label, :string, required: true)
  attr(:count, :any, default: nil)
  attr(:icon, :string, required: true)
  attr(:navigate, :string, required: true)

  defp count_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="card bg-base-100 shadow-sm border border-base-200 hover:border-primary transition-colors"
    >
      <div class="card-body p-4 gap-1">
        <div class="flex items-center gap-2 text-base-content/60">
          <.icon name={@icon} class="w-4 h-4" />
          <span class="text-sm">{@label}</span>
        </div>
        <%!-- nil means the connected mount has not loaded yet; an em dash is
             honest, a zero would be a claim we cannot make. --%>
        <div class="text-2xl font-semibold">{if is_nil(@count), do: "—", else: @count}</div>
      </div>
    </.link>
    """
  end
end
