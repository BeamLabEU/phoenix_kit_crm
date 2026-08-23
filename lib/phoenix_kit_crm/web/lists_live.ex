defmodule PhoenixKitCRM.Web.ListsLive do
  @moduledoc "Admin list of CRM contact lists (card/table toggle view)."
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKitCRM.{Activity, Lists, Paths}
  alias PhoenixKitCRM.PubSub, as: CRMPubSub
  alias PhoenixKitCRM.Schemas.ContactList

  # crm:lists also carries contact-scoped events (:contact_opt_out,
  # :contact_opt_in) that don't touch anything this index page renders
  # (name/slug/subscribable/status/subscriber_count) — reload only for the
  # events that can actually change one of those.
  @list_events ~w(list_created list_updated list_archived list_unarchived list_recounted member_added member_removed)a

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: CRMPubSub.subscribe(CRMPubSub.topic_lists())

    {:ok, assign(socket, page_title: gettext("CRM — Lists"), filter: "active", lists: [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = if params["filter"] == "archived", do: "archived", else: "active"
    {:noreply, socket |> assign(:filter, filter) |> load()}
  end

  defp load(socket) do
    assign(socket, :lists, Lists.list_lists(status: socket.assigns.filter))
  end

  @impl true
  def handle_event("toggle_subscribable", %{"uuid" => uuid}, socket) do
    with %ContactList{} = list <- Lists.get_list(uuid),
         {:ok, _} <-
           Lists.update_list(
             list,
             %{"subscribable" => !list.subscribable},
             Activity.actor_opts(socket)
           ) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not update list"))}
    end
  end

  def handle_event("archive", %{"uuid" => uuid}, socket) do
    with %ContactList{} = list <- Lists.get_list(uuid),
         {:ok, _} <- Lists.archive_list(list, Activity.actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, gettext("List archived")) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not archive list"))}
    end
  end

  def handle_event("unarchive", %{"uuid" => uuid}, socket) do
    with %ContactList{} = list <- Lists.get_list(uuid),
         {:ok, _} <- Lists.unarchive_list(list, Activity.actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, gettext("List unarchived")) |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not unarchive list"))}
    end
  end

  @impl true
  def handle_info({:crm, event, _payload}, socket) when event in @list_events do
    {:noreply, load(socket)}
  end

  def handle_info({:crm, _event, _payload}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <.nav_tabs
        variant={:border}
        active_tab={@filter}
        tabs={[
          %{id: "active", label: gettext("Active"), patch: Paths.lists()},
          %{id: "archived", label: gettext("Archived"), patch: Paths.lists() <> "?filter=archived"}
        ]}
      />

      <.empty_state
        :if={@lists == []}
        icon="hero-envelope"
        title={empty_title(@filter)}
        variant="card"
      >
        <.link :if={@filter == "active"} navigate={Paths.list_new()} class="btn btn-primary">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create first list")}
        </.link>
      </.empty_state>

      <.table_default
        :if={@lists != []}
        id="crm-lists-table"
        toggleable
        items={@lists}
        card_title={fn l -> card_title_link(l) end}
        card_fields={fn l -> card_fields(l) end}
      >
        <:toolbar_title>
          <span class="text-sm text-base-content/60">
            {ngettext("%{count} list", "%{count} lists", length(@lists), count: length(@lists))}
          </span>
        </:toolbar_title>
        <:toolbar_actions>
          <.link navigate={Paths.comparison()} class="btn btn-outline btn-sm">
            <.icon name="hero-arrows-right-left" class="w-4 h-4" /> {gettext("Compare")}
          </.link>
          <.link navigate={Paths.list_new()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New list")}
          </.link>
        </:toolbar_actions>

        <:card_actions :let={list}>
          {row_menu(%{list: list, filter: @filter, id_suffix: "card"})}
        </:card_actions>

        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Subscribable")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Locale")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right">
              {gettext("Subscribers")}
            </.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">
              {gettext("Actions")}
            </.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={list <- @lists}>
            <.table_default_cell class="font-medium">
              <.link navigate={Paths.list_members(list.uuid)} class="link link-hover">
                {list.name}
              </.link>
              <div class="text-xs text-base-content/50">{list.slug}</div>
            </.table_default_cell>
            <.table_default_cell><.status_badge status={list.status} size={:sm} /></.table_default_cell>
            <.table_default_cell>
              <.checkbox
                name={"list_#{list.uuid}_subscribable"}
                checked={list.subscribable}
                phx-click="toggle_subscribable"
                phx-value-uuid={list.uuid}
                aria-label={gettext("Subscribable")}
              />
            </.table_default_cell>
            <.table_default_cell class="text-base-content/70">{list_locale(list)}</.table_default_cell>
            <.table_default_cell class="text-right">{list.subscriber_count}</.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              {row_menu(%{list: list, filter: @filter, id_suffix: "table"})}
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </div>
    """
  end

  defp card_title_link(list) do
    assigns = %{list: list}

    ~H"""
    <.link navigate={Paths.list_members(@list.uuid)} class="link link-hover">{@list.name}</.link>
    """
  end

  defp card_fields(list) do
    [
      %{label: gettext("Slug"), value: list.slug},
      %{label: gettext("Status"), value: list.status},
      %{label: gettext("Locale"), value: list_locale(list)},
      %{label: gettext("Subscribers"), value: list.subscriber_count}
    ]
  end

  defp list_locale(%ContactList{locale: locale}) when is_binary(locale) and locale != "",
    do: locale

  defp list_locale(_), do: "—"

  defp empty_title("archived"), do: gettext("No archived lists.")
  defp empty_title(_), do: gettext("No lists yet.")

  # `id_suffix` distinguishes the table-cell and card_actions renders — the
  # toggleable table_default keeps BOTH views in the DOM at once (CSS-hidden,
  # not removed), so reusing one id across the two would be a real duplicate.
  defp row_menu(assigns) do
    ~H"""
    <.table_row_menu id={"crm-list-menu-#{@id_suffix}-#{@list.uuid}"}>
      <.table_row_menu_link
        navigate={Paths.list_members(@list.uuid)}
        icon="hero-users"
        label={gettext("Members")}
      />
      <.table_row_menu_link
        navigate={Paths.list_edit(@list.uuid)}
        icon="hero-pencil"
        label={gettext("Edit")}
      />
      <.table_row_menu_divider />
      <%= if @filter == "archived" do %>
        <.table_row_menu_button
          phx-click="unarchive"
          phx-value-uuid={@list.uuid}
          phx-disable-with={gettext("Unarchiving…")}
          icon="hero-arrow-uturn-left"
          label={gettext("Unarchive")}
          variant="success"
        />
      <% else %>
        <.table_row_menu_button
          phx-click="archive"
          phx-value-uuid={@list.uuid}
          phx-disable-with={gettext("Archiving…")}
          data-confirm={gettext("Archive this list?")}
          icon="hero-archive-box"
          label={gettext("Archive")}
          variant="error"
        />
      <% end %>
    </.table_row_menu>
    """
  end
end
