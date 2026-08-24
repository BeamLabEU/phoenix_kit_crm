defmodule PhoenixKitCRM.Web.CompanyInteractionsComponent do
  @moduledoc """
  The **Interactions** tab of a CRM company — a read-only, aggregated feed of
  every interaction logged on the company's member contacts. Each entry links to
  the contact it's about (and shows the interaction's parties + attachments), so
  you can jump to that person. Interactions are still *logged* on a contact's
  page; this is a company-wide rollup.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitCRM.Gettext

  import PhoenixKitCRM.Web.Components.TabIntro, only: [tab_intro: 1]
  import PhoenixKitCRM.Web.InteractionHelpers, only: [party_badge: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCRM.{Attachments, Companies, Interactions, Paths}
  alias PhoenixKitCRM.Schemas.{Contact, Interaction}

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:tz_offset, fn -> 0 end)
      # The host's roster — the links to "log one on a member's page".
      |> assign_new(:members, fn -> [] end)

    company_uuid = socket.assigns.company.uuid

    # Read-only rollup: re-query only when the company changes or the host
    # hands in a new `:refresh_token` (its PubSub-driven send_update after a
    # member's interaction changed), so an unrelated host re-render (tab
    # switch, flash) doesn't replay the ~5-7 queries.
    token = socket.assigns[:refresh_token]

    if socket.assigns[:loaded_company_uuid] == company_uuid and
         socket.assigns[:loaded_token] == token do
      {:ok, socket}
    else
      interactions = Interactions.list_for_contacts(member_contact_uuids(company_uuid))

      interaction_files =
        if storage_enabled?(),
          do: Attachments.list_files_by_interaction(Enum.map(interactions, & &1.uuid)),
          else: %{}

      {:ok,
       socket
       |> assign(:interactions, interactions)
       |> assign(:interaction_files, interaction_files)
       |> assign(:loaded_company_uuid, company_uuid)
       |> assign(:loaded_token, token)}
    end
  end

  defp member_contact_uuids(company_uuid) do
    company_uuid |> Companies.list_memberships() |> Enum.map(& &1.contact_uuid)
  end

  defp storage_enabled? do
    Storage.enabled?()
  rescue
    _ -> false
  end

  defp format_local(nil, _offset), do: "—"

  defp format_local(%DateTime{} = utc, offset) do
    utc |> DateTime.add(offset * 3600, :second) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-chat-bubble-left-right" class="w-5 h-5" />
          {gettext("Interactions")} ({length(@interactions)})
        </h2>
        <%!-- Interactions are logged on a PERSON (the interaction's subject is
             a contact), so this tab is a rollup; the sentence says where the
             way in is — the names in the list below are the links. --%>
        <.tab_intro
          text={gettext("Everything logged on this company's contacts, newest first. An interaction is logged on the contact's own page.")}
          class="-mt-1"
        />
        <p :if={@members == []} class="text-sm text-base-content/60 -mt-2">
          {gettext("This company has no contacts yet — add one on the Members tab first.")}
        </p>

        <.empty_state
          :if={@interactions == []}
          icon="hero-chat-bubble-left-right"
          title={gettext("No interactions logged for this company's contacts yet.")}
        />

        <ol :if={@interactions != []} class="flex flex-col gap-3 mt-1">
          <li :for={i <- @interactions} class="rounded-box border border-base-200 p-3 flex flex-col gap-1">
            <div class="flex items-center justify-between gap-2 flex-wrap">
              <.link
                :if={i.contact}
                navigate={Paths.contact(i.contact.uuid)}
                class="font-medium link link-hover inline-flex items-center gap-1.5"
              >
                <.icon name="hero-user" class="w-4 h-4 text-base-content/60" />
                {Contact.display_name(i.contact)}
              </.link>
              <div class="flex items-center gap-2">
                <span class="badge badge-ghost badge-sm">{Interaction.type_label(i.interaction_type)}</span>
                <span class="text-xs text-base-content/60">{format_local(i.occurred_at, @tz_offset)}</span>
              </div>
            </div>

            <div :if={i.subject} class="text-sm font-medium">{i.subject}</div>
            <div :if={i.body} class="text-sm whitespace-pre-wrap">{i.body}</div>

            <div :if={i.parties != []} class="flex flex-wrap gap-1 mt-1">
              <span class="text-xs text-base-content/50">{gettext("Involved:")}</span>
              <.party_badge :for={p <- i.parties} party={p} />
            </div>

            <% files = Map.get(@interaction_files, i.uuid, []) %>
            <div :if={files != []} class="flex flex-wrap gap-2 mt-1">
              <a
                :for={f <- files}
                href={Attachments.download_url(f)}
                target="_blank"
                rel="noopener"
                class="inline-flex items-center gap-1 badge badge-ghost badge-sm hover:badge-outline"
                title={f.original_file_name || f.file_name}
              >
                <.icon name={Attachments.file_icon(f)} class="w-3.5 h-3.5 shrink-0" />
                <span class="max-w-[10rem] truncate">{f.original_file_name || f.file_name}</span>
              </a>
            </div>
          </li>
        </ol>
      </div>
    </div>
    """
  end
end
