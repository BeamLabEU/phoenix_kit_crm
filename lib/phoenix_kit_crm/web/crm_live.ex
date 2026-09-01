defmodule PhoenixKitCRM.Web.CRMLive do
  @moduledoc """
  Main admin LiveView for the CRM module — the module's landing page.

  An overview, deliberately not a dashboard (the dashboards module owns
  configurable dashboards): a front door that names what the CRM holds and
  routes into it. Companies and contacts lead; the by-role band surfaces the
  party roles (supplier/manufacturer/customer/partner) with each count
  deep-linking to the already-filtered index — a role is a facet of both
  record types, so company and contact counts link separately rather than
  pretending there is one "suppliers" destination. Below: a conditional
  needs-attention row, the newest interactions, and a demoted Lists row.

  A note on what is deliberately NOT here: the product review asked for a
  coverage card reading "N of M order customers have no CRM contact". That number
  cannot be computed here. Orders live in the host application's own tables, and
  this package must not reach into them — the same boundary that put the backfill
  mix task in the host rather than in this module. So while the CRM is empty,
  the page offers its own routes in and names no host importer.

  Portal access (which PhoenixKit roles may open the CRM) is admin
  configuration, not CRM data — it lives on the CRM settings page.

  PhoenixKit wraps this in the admin layout automatically (sidebar, header,
  theme) thanks to the `live_view` field on `admin_tabs/0`.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  import PhoenixKitCRM.Web.InteractionHelpers, only: [format_local: 2, tz_offset: 1]
  # Core's stretched-link overlay (whole row/card clickable via one real <a>);
  # deliberately not auto-imported by `use PhoenixKitWeb` — see its moduledoc.
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKitCRM.{Companies, Contacts, Interactions, Lists, PartyRoles, Paths}
  alias PhoenixKitCRM.Schemas.{Contact, Interaction}

  @recent_limit 6

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("CRM"),
       # Rendered inline in the admin header bar, which truncates — keep it
       # short enough to survive there. The by-role band below names the
       # supplier/manufacturer vocabulary; the subtitle doesn't have to.
       page_subtitle: gettext("Companies, people and the interactions between them"),
       enabled: PhoenixKitCRM.enabled?(),
       tz_offset: tz_offset(socket.assigns[:phoenix_kit_current_user]),
       counts: nil,
       company_roles: nil,
       contact_roles: nil,
       no_contact_companies: nil,
       recent: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # All DB reads wait for the connected mount — the dead render would pay
    # for them and then throw the result away.
    if connected?(socket) and socket.assigns.enabled do
      {:noreply,
       socket
       |> assign(:counts, load_counts())
       |> assign(:company_roles, PartyRoles.role_counts("company"))
       |> assign(:contact_roles, PartyRoles.role_counts("contact"))
       |> assign(:no_contact_companies, Companies.count_companies(without_contacts: true))
       |> assign(:recent, Interactions.list_recent(limit: @recent_limit))}
    else
      {:noreply, socket}
    end
  end

  # Every count must match what the page it links to actually shows, or the
  # card is a lie the user discovers one click later: companies/contacts
  # exclude trashed rows (their lists' default scope) and lists count only
  # active ones (the Lists page opens on the Active tab). No interactions
  # total here — the recent feed replaced the count card, so counting them
  # would be a query nothing renders.
  defp load_counts do
    %{
      companies: Companies.count_companies(),
      contacts: Contacts.count_contacts(),
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

      <%!-- No New-contact/New-company buttons up here (Max, 2026-09-01): the
           contacts and companies subtabs already carry them in their
           toolbars, and the hero cards below are the way in. --%>

      <%!-- Shown only while the CRM is genuinely empty — both record types,
           not just contacts: 9 companies with no contacts is not an empty CRM,
           and telling someone with contacts logged to "start" is worse. --%>
      <div
        :if={@enabled && @counts && @counts.companies == 0 && @counts.contacts == 0}
        class="card bg-base-100 shadow-sm border border-base-200"
      >
        <div class="card-body gap-2">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-arrow-down-tray" class="w-5 h-5 text-primary" />
            {gettext("Start your CRM")}
          </h3>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Add a company or a contact, assign the role it plays in your business, then log calls, emails, meetings and notes from contact pages."
            )}
          </p>
          <div class="flex flex-wrap gap-2">
            <.link navigate={Paths.company_new()} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New company")}
            </.link>
            <.link navigate={Paths.contact_new()} class="btn btn-outline btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New contact")}
            </.link>
            <.link navigate={Paths.lists()} class="btn btn-ghost btn-sm">
              <.icon name="hero-queue-list" class="w-4 h-4" /> {gettext("Import into a list")}
            </.link>
          </div>
        </div>
      </div>

      <%!-- The two record types the CRM is made of. Everything else on the
           page is a way of looking at these. --%>
      <div :if={@enabled} class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.hero_card
          label={gettext("Companies")}
          count={@counts && @counts.companies}
          description={gettext("Legal entities and the roles they play in your business")}
          icon="hero-building-office-2"
          navigate={Paths.companies()}
        />
        <.hero_card
          label={gettext("Contacts")}
          count={@counts && @counts.contacts}
          description={gettext("People, their company memberships and interaction history")}
          icon="hero-user-circle"
          navigate={Paths.contacts()}
        />
      </div>

      <div :if={@enabled}>
        <div class="flex items-baseline justify-between gap-2 flex-wrap mb-3">
          <h3 class="text-lg font-semibold">{gettext("By role")}</h3>
          <%!-- Pre-empts the "5 + 3 + 2 on 9 companies?" misread: roles are
               overlapping facets, not a partition. --%>
          <span class="text-sm text-base-content/60">
            {gettext("A company or person can hold more than one role")}
          </span>
        </div>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
          <.role_tile
            :for={{role, label, icon} <- role_defs()}
            label={label}
            icon={icon}
            company_count={@company_roles && Map.fetch!(@company_roles, role)}
            contact_count={@contact_roles && Map.fetch!(@contact_roles, role)}
            companies_path={filtered_path(Paths.companies(), role)}
            contacts_path={filtered_path(Paths.contacts(), role)}
          />
        </div>
      </div>

      <%!-- Structural hygiene only — a company with nobody to talk to is an
           incomplete CRM record. Cadence judgments ("stale contacts") are a
           dashboard's, not an overview's. The whole section disappears when
           there is nothing to fix. --%>
      <div :if={@enabled && is_integer(@no_contact_companies) && @no_contact_companies > 0}>
        <h3 class="text-lg font-semibold mb-3">{gettext("Needs attention")}</h3>
        <div class="relative card bg-base-100 border border-base-200 hover:border-primary transition-colors">
          <div class="card-body p-4 flex-row items-center justify-between gap-3 flex-wrap">
            <.row_link
              navigate={filtered_path(Paths.companies(), "no-contacts")}
              label={gettext("Review")}
            />
            <div class="flex items-center gap-3">
              <.icon name="hero-exclamation-circle" class="w-5 h-5 text-warning" />
              <span class="text-sm">
                {ngettext(
                  "%{count} company has no contacts",
                  "%{count} companies have no contacts",
                  @no_contact_companies,
                  count: @no_contact_companies
                )}
              </span>
            </div>
            <.link
              navigate={filtered_path(Paths.companies(), "no-contacts")}
              class="btn btn-outline btn-sm relative z-10"
            >
              {gettext("Review")}
            </.link>
          </div>
        </div>
      </div>

      <%!-- Newest interactions across the CRM. There is no interactions index
           page — an interaction lives on its contact — so rows link to the
           contact and the empty state points there too, not at a "view all"
           that doesn't exist. Hidden while there are no contacts at all: the
           start card above already explains the workflow. --%>
      <div :if={@enabled && @counts && @counts.contacts > 0}>
        <h3 class="text-lg font-semibold mb-3">{gettext("Recent interactions")}</h3>

        <div
          :if={@recent == []}
          class="relative card bg-base-100 border border-base-200 hover:border-primary transition-colors"
        >
          <div class="card-body p-4 flex-row items-center justify-between gap-3 flex-wrap">
            <.row_link navigate={Paths.contacts()} label={gettext("Browse contacts")} />
            <div class="flex items-center gap-3">
              <.icon name="hero-chat-bubble-left-right" class="w-5 h-5 text-base-content/60" />
              <span class="text-sm text-base-content/70">
                {gettext(
                  "No interactions logged yet. Calls, emails, meetings and notes are logged from a contact's page."
                )}
              </span>
            </div>
            <.link navigate={Paths.contacts()} class="btn btn-outline btn-sm relative z-10">
              {gettext("Browse contacts")}
            </.link>
          </div>
        </div>

        <ol :if={@recent != []} class="flex flex-col gap-2">
          <%!-- Core row_link makes the whole row click through to the contact;
               the visible name stays plain text so the row carries exactly one
               anchor per destination. --%>
          <li
            :for={i <- @recent}
            class="relative rounded-box border border-base-200 bg-base-100 p-3 flex items-center justify-between gap-3 flex-wrap hover:border-primary transition-colors"
          >
            <div class="flex items-center gap-2 min-w-0">
              <.row_link
                :if={i.contact}
                navigate={Paths.contact(i.contact.uuid)}
                label={Contact.display_name(i.contact)}
              />
              <span class="badge badge-ghost badge-sm shrink-0">
                {Interaction.type_label(i.interaction_type)}
              </span>
              <span :if={i.contact} class="font-medium truncate">
                {Contact.display_name(i.contact)}
              </span>
              <span :if={i.subject} class="text-sm text-base-content/70 truncate">
                {i.subject}
              </span>
            </div>
            <span class="text-xs text-base-content/60 shrink-0">
              {format_local(i.occurred_at, @tz_offset)}
            </span>
          </li>
        </ol>
      </div>

      <%!-- Lists are a tool for grouping contacts, not a third record type —
           one row, not a peer card. Whole row clicks through (stretched link). --%>
      <div
        :if={@enabled}
        class="relative card bg-base-100 border border-base-200 hover:border-primary transition-colors"
      >
        <div class="card-body p-4 flex-row items-center justify-between gap-3 flex-wrap">
          <.row_link navigate={Paths.lists()} label={gettext("Manage lists")} />
          <div class="flex items-center gap-3 min-w-0">
            <.icon name="hero-queue-list" class="w-5 h-5 text-base-content/60" />
            <div class="min-w-0">
              <div class="font-semibold">
                {gettext("Lists")}
                <span :if={@counts} class="text-base-content/60 font-normal">
                  ({@counts.lists})
                </span>
              </div>
              <div class="text-sm text-base-content/60">
                {if @counts && @counts.lists == 0,
                  do:
                    gettext(
                      "Lists are optional — create one when you need to group or import contacts."
                    ),
                  else: gettext("Group contacts for imports and batch work.")}
              </div>
            </div>
          </div>
          <.link navigate={Paths.lists()} class="btn btn-outline btn-sm relative z-10">
            {gettext("Manage lists")}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # Overview order leads with the two the business runs on; the index's tab
  # strip has its own order and both link into the same filters. Labels are
  # the plural forms the destination tabs use, not the singular role badge.
  defp role_defs do
    [
      {"supplier", gettext("Suppliers"), "hero-truck"},
      {"manufacturer", gettext("Manufacturers"), "hero-wrench-screwdriver"},
      {"customer", gettext("Customers"), "hero-user-group"},
      {"partner", gettext("Partners"), "hero-puzzle-piece"}
    ]
  end

  defp filtered_path(base, filter), do: base <> "?filter=" <> filter

  attr(:label, :string, required: true)
  attr(:count, :any, default: nil)
  attr(:description, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:navigate, :string, required: true)

  defp hero_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="card bg-base-100 shadow-sm border border-base-200 hover:border-primary transition-colors"
    >
      <div class="card-body p-5 gap-1">
        <div class="flex items-center gap-2 text-base-content/60">
          <.icon name={@icon} class="w-5 h-5" />
          <span class="text-sm">{@label}</span>
        </div>
        <%!-- nil means the connected mount has not loaded yet; an em dash is
             honest, a zero would be a claim we cannot make. --%>
        <div class="text-3xl font-semibold">{if is_nil(@count), do: "—", else: @count}</div>
        <div class="text-sm text-base-content/60">{@description}</div>
      </div>
    </.link>
    """
  end

  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:company_count, :any, default: nil)
  attr(:contact_count, :any, default: nil)
  attr(:companies_path, :string, required: true)
  attr(:contacts_path, :string, required: true)

  # The whole tile is clickable like the hero cards (Max, 2026-09-01) via
  # core's row_link overlay — a role spans both record types with no combined
  # destination, so the tile can't be one big <a>. The overlay carries the
  # PRIMARY destination (companies; contacts when only contacts hold the
  # role), the visible counts stay plain text, and the secondary contact link
  # stacks above the overlay with z-10 — two real anchors, no illegal nesting.
  # A tile with nothing to open gets no overlay (a filter with no results is a
  # dead end) and dims: "supported, unused" — hiding it would teach users the
  # vocabulary doesn't exist. The CONTACT line is secondary by design and is
  # omitted at zero rather than printing "0 contacts" four times.
  defp role_tile(assigns) do
    company? = is_integer(assigns.company_count) and assigns.company_count > 0
    contact? = is_integer(assigns.contact_count) and assigns.contact_count > 0

    assigns =
      assigns
      |> assign(:company?, company?)
      |> assign(:contact?, contact?)
      |> assign(:unused?, assigns.company_count == 0 and not contact?)
      |> assign(
        :primary_path,
        cond do
          company? -> assigns.companies_path
          contact? -> assigns.contacts_path
          true -> nil
        end
      )

    ~H"""
    <div class={[
      "relative card bg-base-100 shadow-sm border border-base-200",
      @primary_path && "hover:border-primary transition-colors",
      @unused? && "opacity-60"
    ]}>
      <div class="card-body p-4 gap-1">
        <.row_link :if={@primary_path} navigate={@primary_path} label={@label} />
        <div class="flex items-center gap-2 text-base-content/60">
          <.icon name={@icon} class="w-4 h-4" />
          <span class="text-sm">{@label}</span>
        </div>
        <div :if={is_nil(@company_count)} class="text-2xl font-semibold">—</div>
        <div :if={@company?}>
          <span class="text-2xl font-semibold">{@company_count}</span>
          <span class="text-sm text-base-content/60">
            {ngettext("company", "companies", @company_count)}
          </span>
        </div>
        <div :if={@company_count == 0} class="text-base-content/50">
          <span class="text-2xl font-semibold">0</span>
          <span class="text-sm">{ngettext("company", "companies", 0)}</span>
        </div>
        <.link
          :if={@contact?}
          navigate={@contacts_path}
          class="link link-hover text-sm text-base-content/60 relative z-10 self-start"
        >
          {ngettext("%{count} contact", "%{count} contacts", @contact_count,
            count: @contact_count
          )}
        </.link>
      </div>
    </div>
    """
  end
end
