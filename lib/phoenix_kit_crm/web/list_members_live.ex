defmodule PhoenixKitCRM.Web.ListMembersLive do
  @moduledoc """
  Admin page for a single CRM contact list's memberships — paginated member
  table (status/source/email, remove action) plus a manual add-by-email form.

  The add form always creates a brand-new contact (`Lists.add_new_contact_to_list/3`),
  matching the import engine's policy — except when the typed email already
  holds a `"removed"` slot in this list (`idx_crm_list_members_list_email`),
  in which case a new-contact insert would just fail. That case gets its own
  "Resubscribe" affordance instead: reactivates the EXISTING contact's
  membership (`Lists.add_contact_to_list/3`) rather than trying (and
  failing) to create a second contact for the same email. Resubscribe never
  touches the found contact's name/locale — only the membership.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKitCRM.{Activity, Lists, Paths}
  alias PhoenixKitCRM.PubSub, as: CRMPubSub
  alias PhoenixKitCRM.Schemas.{Contact, ListMember}

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: CRMPubSub.subscribe(CRMPubSub.topic_lists())

    {:ok,
     socket
     |> assign(:members, [])
     |> assign(:has_more?, false)
     |> assign(:add_form, blank_add_form())
     |> assign(:email_check, nil)
     |> assign(:show_locale_modal, false)
     |> assign(:locale_mode, "missing_only")
     |> assign(:locale_preview, %{total: 0, missing_locale: 0, different_locale: 0})}
  end

  @impl true
  def handle_params(%{"uuid" => uuid} = params, _uri, socket) do
    case Lists.get_list(uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("List not found"))
         |> push_navigate(to: Paths.lists())}

      list ->
        filter =
          case params["status"] do
            s when s in ~w(subscribed pending removed) -> s
            _ -> nil
          end

        page = parse_page(params["page"])

        # Plug decodes ?search[x]=y as a map/list — a forged non-binary
        # search param would crash URI.encode_query in members_path/2 below.
        search =
          case params["search"] do
            s when is_binary(s) -> s
            _ -> ""
          end

        {:noreply,
         socket
         |> assign(:list, list)
         |> assign(:page_title, gettext("CRM — %{name}", name: list.name))
         |> assign(:page_subtitle, list_subtitle(list))
         |> assign(:page_section, gettext("Lists"))
         |> assign(:page_section_path, Paths.lists())
         |> assign(:filter, filter)
         |> assign(:page, page)
         |> assign(:search, search)
         |> load_members()}
    end
  end

  # ── Search / pagination ──────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"search" => term}, socket) when is_binary(term) do
    {:noreply, push_patch(socket, to: members_path(socket.assigns, search: term, page: 1))}
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket, to: members_path(socket.assigns, status: presence(status), page: 1))}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply,
     push_patch(socket, to: members_path(socket.assigns, page: socket.assigns.page + 1))}
  end

  def handle_event("prev_page", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: members_path(socket.assigns, page: max(socket.assigns.page - 1, 1))
     )}
  end

  # ── Manual add-by-email ───────────────────────────────────────────────

  def handle_event("check_email", %{"add_member" => params}, socket) do
    {:noreply,
     socket
     |> assign(:add_form, to_form(params, as: :add_member))
     |> assign(:email_check, check_email(socket.assigns.list, params["email"]))}
  end

  def handle_event("add_member", %{"add_member" => params}, socket) do
    case socket.assigns.email_check do
      {:removed, _} -> {:noreply, socket}
      {:active, _} -> {:noreply, socket}
      _ -> do_add_member(socket, params)
    end
  end

  def handle_event("resubscribe", _params, socket) do
    case socket.assigns.email_check do
      {:removed, %ListMember{contact: %Contact{} = contact}} ->
        resubscribe(socket, contact)

      {:removed, %ListMember{}} ->
        # The membership's contact row is gone entirely (only possible via a
        # direct DB delete — contacts are soft-deleted, which keeps the
        # preload intact). Fabricating a bare %Contact{} here would
        # reactivate the membership with email: nil, wiping the denormalized
        # email slot that idx_crm_list_members_list_email guards.
        {:noreply, put_flash(socket, :error, gettext("Could not resubscribe this contact"))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("resubscribe_row", %{"contact_uuid" => contact_uuid}, socket) do
    case Enum.find(socket.assigns.members, &(&1.contact_uuid == contact_uuid)) do
      %ListMember{contact: %Contact{} = contact} -> resubscribe(socket, contact)
      _ -> {:noreply, socket}
    end
  end

  # ── Removal ─────────────────────────────────────────────────────────

  def handle_event("remove_member", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.members, &(&1.uuid == uuid)) do
      nil ->
        {:noreply, socket}

      member ->
        {:ok, _} = Lists.remove_from_list(member, Activity.actor_opts(socket))
        {:noreply, socket |> put_flash(:info, gettext("Member removed")) |> load_members()}
    end
  end

  # ── Bulk-apply list locale to members ─────────────────────────────────

  def handle_event("open_locale_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_locale_modal, true)
     |> assign(:locale_mode, "missing_only")
     |> assign(:locale_preview, Lists.locale_apply_preview(socket.assigns.list))}
  end

  def handle_event("close_locale_modal", _params, socket) do
    {:noreply, assign(socket, :show_locale_modal, false)}
  end

  def handle_event("set_locale_mode", %{"mode" => mode}, socket)
      when mode in ~w(missing_only all) do
    {:noreply, assign(socket, :locale_mode, mode)}
  end

  def handle_event("apply_locale", _params, socket) do
    mode = String.to_existing_atom(socket.assigns.locale_mode)

    case Lists.apply_locale_to_members(socket.assigns.list, mode, Activity.actor_opts(socket)) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign(:show_locale_modal, false)
         |> put_flash(
           :info,
           ngettext(
             "Locale applied to %{count} contact",
             "Locale applied to %{count} contacts",
             count,
             count: count
           )
         )
         |> load_members()}

      {:error, :no_locale} ->
        {:noreply,
         socket
         |> assign(:show_locale_modal, false)
         |> put_flash(:error, gettext("This list has no locale set"))}
    end
  end

  @impl true
  def handle_info({:crm, _event, %{list_uuid: list_uuid}}, socket) do
    if list_uuid == socket.assigns.list.uuid do
      {:noreply, load_members(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Private helpers ─────────────────────────────────────────────────

  defp load_members(socket) do
    socket = fetch_members(socket)

    # No real total-pages here (this page's pagination is the "peek at
    # limit+1" has_more? scheme, not a COUNT query) — but an out-of-range
    # page (a stale bookmark, a bulk remove that shrank the last page, or a
    # forged ?page=) still shouldn't show the user an unexplained empty
    # table. If the requested page came back empty and it wasn't actually
    # page 1, that's the tell — patch back to page 1 (handle_params then
    # refetches), which also fixes the address bar so a refresh doesn't
    # re-run the double fetch.
    if socket.assigns.members == [] and socket.assigns.page > 1 do
      push_patch(socket, to: members_path(socket.assigns, page: 1))
    else
      socket
    end
  end

  defp fetch_members(socket) do
    %{list: list, filter: filter, page: page, search: search} = socket.assigns

    opts =
      [limit: @page_size + 1, offset: (page - 1) * @page_size]
      |> maybe_put(:status, filter)
      |> maybe_put(:search, if(search == "", do: nil, else: search))

    members = Lists.list_members(list, opts)
    has_more? = length(members) > @page_size
    refreshed_list = Lists.get_list!(list.uuid)

    socket
    |> assign(:members, Enum.take(members, @page_size))
    |> assign(:has_more?, has_more?)
    |> assign(:list, refreshed_list)
    |> assign(:page_subtitle, list_subtitle(refreshed_list))
  end

  defp list_subtitle(list) do
    ngettext("%{count} subscriber", "%{count} subscribers", list.subscriber_count,
      count: list.subscriber_count
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # `String.to_integer/1` raises on anything non-numeric — a fat-fingered
  # bookmark or a crawler hitting `?page=abc` (or a stray trailing
  # `?page=`) would crash the LiveView. `Integer.parse/1` doesn't raise;
  # anything it can't read at all (or the `nil` from no param) falls back
  # to page 1. Plug decodes `?page[a]=1` as a map/list, so a non-binary
  # param falls back too rather than raising in Integer.parse/1.
  defp parse_page(param) when is_binary(param) do
    case Integer.parse(param) do
      {n, _rest} -> max(n, 1)
      :error -> 1
    end
  end

  defp parse_page(_), do: 1

  defp blank_add_form,
    do: to_form(%{"email" => "", "name" => "", "locale" => ""}, as: :add_member)

  defp presence(""), do: nil
  defp presence(v), do: v

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # How many contacts the CURRENTLY SELECTED mode would actually touch —
  # `:all` touches every subscribed member (`total`), `:missing_only`
  # touches only the subset with no locale yet (`missing_locale`). Showing
  # `total` regardless of mode overstated the impact for `:missing_only`
  # (the default mode) whenever some members already had a different
  # locale — this keeps the confirm modal's number matching what
  # apply_locale_to_members/3 will actually do.
  defp affected_count(%{total: total}, "all"), do: total
  defp affected_count(%{missing_locale: missing}, _mode), do: missing

  # Takes an assigns-shaped map — either a LiveView `socket.assigns` (from an
  # event handler) or the `assigns` passed into `render/1` (from the
  # template) — both expose `:filter`/`:search`/`:page`/`:list` the same way.
  defp members_path(assigns, overrides) do
    params =
      %{status: assigns.filter, search: assigns.search, page: assigns.page}
      |> Map.merge(Map.new(overrides))
      |> Enum.reject(fn {_k, v} -> v in [nil, "", 1] end)
      |> Enum.into(%{})

    case params do
      empty when map_size(empty) == 0 -> Paths.list_members(assigns.list.uuid)
      _ -> Paths.list_members(assigns.list.uuid) <> "?" <> URI.encode_query(params)
    end
  end

  defp check_email(_list, email) when email in [nil, ""], do: nil

  defp check_email(list, email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    case Lists.get_member_by_email(list, normalized) do
      nil -> :none
      %ListMember{status: "removed"} = member -> {:removed, member}
      %ListMember{} = member -> {:active, member}
    end
  end

  # A forged event with a non-binary email value — treat as "no check".
  defp check_email(_list, _email), do: nil

  defp do_add_member(socket, params) do
    attrs = Map.take(params, ["email", "name", "locale"])

    case Lists.add_new_contact_to_list(attrs, socket.assigns.list, Activity.actor_opts(socket)) do
      {:ok, {_contact, _member}} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Contact added to the list"))
         |> assign(:add_form, blank_add_form())
         |> assign(:email_check, nil)
         |> load_members()}

      {:error, :email_already_in_list} ->
        # Race: the slot got taken between the live check and submit — re-run
        # the check so the UI catches up (e.g. shows Resubscribe now).
        {:noreply,
         socket
         |> assign(:add_form, to_form(params, as: :add_member))
         |> assign(:email_check, check_email(socket.assigns.list, params["email"]))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :add_form, to_form(changeset, as: :add_member))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add this contact"))}
    end
  end

  defp resubscribe(socket, %Contact{} = contact) do
    case Lists.add_contact_to_list(contact, socket.assigns.list, Activity.actor_opts(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Contact resubscribed"))
         |> assign(:add_form, blank_add_form())
         |> assign(:email_check, nil)
         |> load_members()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not resubscribe this contact"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="font-semibold flex items-center gap-2">
            <.icon name="hero-user-plus" class="w-5 h-5" /> {gettext("Add a contact")}
          </h2>

          <.form
            for={@add_form}
            id="crm-list-add-member-form"
            phx-change="check_email"
            phx-submit="add_member"
            class="grid gap-3 sm:grid-cols-3"
          >
            <.input
              field={@add_form[:email]}
              type="email"
              label={gettext("Email")}
              phx-debounce="300"
              required
            />
            <.input field={@add_form[:name]} label={gettext("Name (optional)")} />
            <.input field={@add_form[:locale]} label={gettext("Locale (optional)")} placeholder="en" />

            <div class="sm:col-span-3 flex items-center gap-3">
              <%= case @email_check do %>
                <% {:active, _} -> %>
                  <span class="badge badge-warning gap-1">
                    <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                    {gettext("Already in this list")}
                  </span>
                <% {:removed, member} -> %>
                  <span class="badge badge-info gap-1">
                    <.icon name="hero-information-circle" class="w-3 h-3" />
                    {gettext("Previously unsubscribed: %{name}",
                      name: contact_label(member.contact)
                    )}
                  </span>
                  <.button
                    type="button"
                    phx-click="resubscribe"
                    class="btn-sm btn-outline btn-info"
                    phx-disable-with={gettext("Resubscribing…")}
                  >
                    {gettext("Resubscribe")}
                  </.button>
                <% _ -> %>
                  <.button
                    type="submit"
                    class="btn-sm btn-primary"
                    phx-disable-with={gettext("Adding…")}
                  >
                    {gettext("Add to list")}
                  </.button>
              <% end %>
            </div>
          </.form>
        </div>
      </div>

      <div class="flex flex-col gap-3">
        <div class="flex items-center justify-between flex-wrap gap-2">
          <div role="tablist" class="tabs tabs-border">
            <.link
              patch={members_path(assigns, status: nil, page: 1)}
              role="tab"
              class={["tab", is_nil(@filter) && "tab-active"]}
            >
              {gettext("All")}
            </.link>
            <.link
              patch={members_path(assigns, status: "subscribed", page: 1)}
              role="tab"
              class={["tab", @filter == "subscribed" && "tab-active"]}
            >
              {gettext("Subscribed")}
            </.link>
            <.link
              patch={members_path(assigns, status: "removed", page: 1)}
              role="tab"
              class={["tab", @filter == "removed" && "tab-active"]}
            >
              {gettext("Removed")}
            </.link>
          </div>

          <div class="flex items-center gap-2">
            <button
              type="button"
              class="btn btn-outline btn-sm"
              disabled={blank?(@list.locale)}
              title={
                if blank?(@list.locale), do: gettext("Set a locale on this list first"), else: nil
              }
              phx-click="open_locale_modal"
            >
              <.icon name="hero-language" class="w-4 h-4" /> {gettext("Apply list locale to contacts")}
            </button>
            <.link navigate={Paths.list_import(@list.uuid)} class="btn btn-outline btn-sm">
              <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> {gettext("Import")}
            </.link>
            <.link navigate={Paths.list_edit(@list.uuid)} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Edit list")}
            </.link>
          </div>
        </div>

        <div class="w-full sm:w-64 self-end">
          <.search_toolbar
            name="search"
            value={@search}
            placeholder={gettext("Search email/name")}
            on_submit="search"
          />
        </div>
      </div>

      <.modal
        show={@show_locale_modal}
        on_close="close_locale_modal"
        id="crm-list-locale-modal"
        max_width="md"
      >
        <:title>{gettext("Apply list locale to contacts")}</:title>
        <div class="flex flex-col gap-4">
          <p class="text-sm text-base-content/70">
            {gettext("This list's locale is %{locale}.", locale: @list.locale)}
          </p>
          <p class="text-sm">
            {ngettext(
              "%{count} subscribed contact will be affected.",
              "%{count} subscribed contacts will be affected.",
              affected_count(@locale_preview, @locale_mode),
              count: affected_count(@locale_preview, @locale_mode)
            )}
          </p>
          <p :if={@locale_preview.different_locale > 0} class="text-sm text-warning">
            <%= if @locale_mode == "all" do %>
              {ngettext(
                "%{count} of them already has a different locale set — it will be overwritten.",
                "%{count} of them already have a different locale set — they will be overwritten.",
                @locale_preview.different_locale,
                count: @locale_preview.different_locale
              )}
            <% else %>
              {ngettext(
                "%{count} contact already has a different locale set and will be left unchanged.",
                "%{count} contacts already have a different locale set and will be left unchanged.",
                @locale_preview.different_locale,
                count: @locale_preview.different_locale
              )}
            <% end %>
          </p>

          <fieldset class="flex flex-col gap-2">
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="radio"
                name="locale_mode"
                class="radio radio-sm"
                checked={@locale_mode == "missing_only"}
                phx-click="set_locale_mode"
                phx-value-mode="missing_only"
              />
              <span class="fieldset-legend">{gettext("Only contacts without a locale")}</span>
            </label>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="radio"
                name="locale_mode"
                class="radio radio-sm"
                checked={@locale_mode == "all"}
                phx-click="set_locale_mode"
                phx-value-mode="all"
              />
              <span class="fieldset-legend">{gettext("All (overwrite existing locale)")}</span>
            </label>
          </fieldset>
        </div>

        <:actions>
          <button type="button" class="btn btn-ghost" phx-click="close_locale_modal">
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            class="btn btn-primary"
            phx-click="apply_locale"
            phx-disable-with={gettext("Applying…")}
            disabled={affected_count(@locale_preview, @locale_mode) == 0}
          >
            {gettext("Apply")}
          </button>
        </:actions>
      </.modal>

      <.empty_state
        :if={@members == []}
        icon="hero-users"
        title={gettext("No members yet.")}
        variant="card"
      />

      <.table_default :if={@members != []} id="crm-list-members-table" size="sm">
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{gettext("Contact")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Email")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Locale")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Source")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">
              {gettext("Actions")}
            </.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={member <- @members}>
            <.table_default_cell class="font-medium">
              <.link
                :if={member.contact}
                navigate={Paths.contact(member.contact_uuid)}
                class="link link-hover"
              >
                {contact_label(member.contact)}
              </.link>
              <span :if={!member.contact} class="text-base-content/40">—</span>
            </.table_default_cell>
            <.table_default_cell class="text-base-content/70">{member.email || "—"}</.table_default_cell>
            <.table_default_cell class="text-base-content/70">{member_locale(member)}</.table_default_cell>
            <.table_default_cell>{member_status_badge(member.status)}</.table_default_cell>
            <.table_default_cell class="text-base-content/70">{member.source}</.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <button
                :if={member.status != "removed"}
                type="button"
                phx-click="remove_member"
                phx-value-uuid={member.uuid}
                data-confirm={gettext("Remove this member from the list?")}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Remove")}
              </button>
              <button
                :if={member.status == "removed" && member.contact}
                type="button"
                phx-click="resubscribe_row"
                phx-value-contact_uuid={member.contact_uuid}
                class="btn btn-ghost btn-xs text-info"
              >
                <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Resubscribe")}
              </button>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>

      <div :if={@page > 1 or @has_more?} class="flex items-center justify-center gap-2">
        <span class="text-sm text-base-content/60">{gettext("Page %{n}", n: @page)}</span>
        <div class="join">
          <button
            type="button"
            class="join-item btn btn-sm btn-ghost"
            disabled={@page <= 1}
            phx-click="prev_page"
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" /> {gettext("Previous")}
          </button>
          <button
            type="button"
            class="join-item btn btn-sm btn-ghost"
            disabled={!@has_more?}
            phx-click="next_page"
          >
            {gettext("Next")} <.icon name="hero-chevron-right" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp contact_label(%Contact{} = contact), do: Contact.display_name(contact)
  defp contact_label(_), do: "—"

  defp member_locale(%ListMember{contact: %Contact{locale: locale}})
       when is_binary(locale) and locale != "",
       do: locale

  defp member_locale(_), do: "—"

  # `.status_badge` has no "subscribed" mapping (falls through to ghost/gray),
  # which reads as neutral rather than active — give it its own success color.
  # "pending"/"removed" already get a sensible default from `.status_badge`.
  defp member_status_badge("subscribed") do
    assigns = %{}

    ~H"""
    <span class="badge badge-success badge-sm">{gettext("Subscribed")}</span>
    """
  end

  defp member_status_badge(status) do
    assigns = %{status: status}

    ~H"""
    <.status_badge status={@status} size={:sm} />
    """
  end
end
