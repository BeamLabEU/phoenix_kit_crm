defmodule PhoenixKitCRM.Web.ComparisonLive do
  @moduledoc """
  CRM comparison ("сличение") screen — two independent, read-only reports,
  no auto-actions:

    * Directory-wide duplicate emails: contacts sharing the same email
      (across the whole CRM, not scoped to any list), with a count and an
      expandable drill-down to the actual contacts.
    * Cross-list overlap: pick 2+ active lists, see the contacts with an
      active membership on ALL of them.

  Neither section offers to merge, remove, or otherwise act on what it
  shows — this is purely a "here's what overlaps" report; any consolidation
  is a manual, human decision the operator makes from the linked
  contact/list pages.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKitCRM.{Contacts, Lists, Paths}
  alias PhoenixKitCRM.Schemas.Contact

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("CRM — Comparison"))
     |> assign(:page_subtitle, gettext("Read-only reports — nothing here changes any data."))
     |> assign(:page_section, gettext("Lists"))
     |> assign(:page_section_path, Paths.lists())
     |> assign(:expanded_duplicates, MapSet.new())
     |> assign(:duplicate_contacts, %{})
     |> assign(:selected_list_uuids, MapSet.new())
     |> assign(:overlap_contacts, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:duplicate_groups, Contacts.list_duplicate_email_groups())
     |> assign(:lists, Lists.list_lists(status: "active"))}
  end

  @impl true
  def handle_event("toggle_duplicate", %{"email" => email}, socket) do
    if MapSet.member?(socket.assigns.expanded_duplicates, email) do
      {:noreply,
       assign(
         socket,
         :expanded_duplicates,
         MapSet.delete(socket.assigns.expanded_duplicates, email)
       )}
    else
      contacts =
        Map.get_lazy(socket.assigns.duplicate_contacts, email, fn ->
          Contacts.list_by_email(email)
        end)

      {:noreply,
       socket
       |> assign(:expanded_duplicates, MapSet.put(socket.assigns.expanded_duplicates, email))
       |> assign(:duplicate_contacts, Map.put(socket.assigns.duplicate_contacts, email, contacts))}
    end
  end

  def handle_event("toggle_list", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.selected_list_uuids

    selected =
      if MapSet.member?(selected, uuid),
        do: MapSet.delete(selected, uuid),
        else: MapSet.put(selected, uuid)

    overlap_contacts =
      if MapSet.size(selected) >= 2, do: Lists.list_overlap(MapSet.to_list(selected))

    {:noreply,
     socket
     |> assign(:selected_list_uuids, selected)
     |> assign(:overlap_contacts, overlap_contacts)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="font-semibold flex items-center gap-2">
            <.icon name="hero-identification" class="w-5 h-5" />
            {gettext("Duplicate emails")}
          </h2>
          <p class="text-sm text-base-content/60">
            {gettext("Contacts across the whole CRM that share the same email address.")}
          </p>

          <.empty_state
            :if={@duplicate_groups == []}
            icon="hero-check-circle"
            title={gettext("No duplicate emails found.")}
            variant="card"
          />

          <div :if={@duplicate_groups != []} class="flex flex-col gap-2">
            <div
              :for={group <- @duplicate_groups}
              class="collapse collapse-arrow bg-base-200/50 border border-base-200"
            >
              <input
                type="checkbox"
                checked={MapSet.member?(@expanded_duplicates, group.email)}
                phx-click="toggle_duplicate"
                phx-value-email={group.email}
              />
              <div class="collapse-title font-medium flex items-center gap-2">
                <span>{group.email}</span>
                <span class="badge badge-warning badge-sm">
                  {ngettext("%{count} contact", "%{count} contacts", group.count,
                    count: group.count
                  )}
                </span>
              </div>
              <div class="collapse-content">
                <ul
                  :if={contacts = Map.get(@duplicate_contacts, group.email)}
                  class="text-sm flex flex-col gap-1"
                >
                  <li :for={contact <- contacts}>
                    <.link navigate={Paths.contact(contact.uuid)} class="link link-hover">
                      {Contact.display_name(contact)}
                    </.link>
                    <span class="text-base-content/50">— {gettext("added")} {Calendar.strftime(
                      contact.inserted_at,
                      "%Y-%m-%d"
                    )}</span>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="font-semibold flex items-center gap-2">
            <.icon name="hero-arrows-right-left" class="w-5 h-5" /> {gettext("List overlap")}
          </h2>
          <p class="text-sm text-base-content/60">
            {gettext("Pick 2 or more lists to see contacts subscribed to all of them.")}
          </p>

          <.empty_state
            :if={@lists == []}
            icon="hero-envelope"
            title={gettext("No active lists yet.")}
            variant="card"
          />

          <div :if={@lists != []} class="flex flex-wrap gap-3">
            <.checkbox
              :for={list <- @lists}
              name={"compare_list_#{list.uuid}"}
              checked={MapSet.member?(@selected_list_uuids, list.uuid)}
              label={list.name}
              phx-click="toggle_list"
              phx-value-uuid={list.uuid}
              class="checkbox-sm"
              wrapper_class="border border-base-200 rounded-lg px-3 py-2"
            />
          </div>

          <p
            :if={@lists != [] and MapSet.size(@selected_list_uuids) < 2}
            class="text-sm text-base-content/50"
          >
            {gettext("Select at least 2 lists to compare.")}
          </p>

          <div :if={@overlap_contacts}>
            <.empty_state
              :if={@overlap_contacts == []}
              icon="hero-arrows-right-left"
              title={gettext("No contacts are subscribed to all selected lists.")}
              variant="card"
            />

            <.table_default :if={@overlap_contacts != []} id="crm-comparison-overlap-table" size="sm">
              <.table_default_header>
                <.table_default_row>
                  <.table_default_header_cell>{gettext("Contact")}</.table_default_header_cell>
                  <.table_default_header_cell>{gettext("Email")}</.table_default_header_cell>
                </.table_default_row>
              </.table_default_header>
              <.table_default_body>
                <.table_default_row :for={contact <- @overlap_contacts}>
                  <.table_default_cell>
                    <.link navigate={Paths.contact(contact.uuid)} class="link link-hover">
                      {Contact.display_name(contact)}
                    </.link>
                  </.table_default_cell>
                  <.table_default_cell class="text-base-content/70">
                    {contact.email || "—"}
                  </.table_default_cell>
                </.table_default_row>
              </.table_default_body>
            </.table_default>

            <p :if={@overlap_contacts != []} class="text-sm text-base-content/60 mt-2">
              {ngettext("%{count} contact in common", "%{count} contacts in common",
                length(@overlap_contacts),
                count: length(@overlap_contacts)
              )}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
