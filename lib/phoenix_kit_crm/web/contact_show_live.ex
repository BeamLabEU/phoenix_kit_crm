defmodule PhoenixKitCRM.Web.ContactShowLive do
  @moduledoc """
  Show page for a CRM contact. Tabs: Overview, Interactions, Events always;
  Orders when the host app's `Andi.CRMBridge` is available; Files + Images
  when core Storage is enabled; Comments when the comments module is
  enabled. The header shows a circular avatar (initials fallback).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext
  # Forwards the comment composer's {:leaf_changed, …} into CommentsComponent via
  # a composing on_mount hook (the current pattern — see PhoenixKitComments.Embed).
  use PhoenixKitComments.Embed

  require Logger

  # Guarded soft-dependency on Andi (the host app) for the Orders tab. CRM has
  # no compile-time dependency on Andi — `Andi.CRMBridge` is absent from this
  # package's own mix.exs and its test suite — so a plain qualified call would
  # warn under `--warnings-as-errors` there. Same idiom as
  # `PhoenixKitCRM.StaffLink`'s guard on the optional `phoenix_kit_staff` dep
  # (`staff_link.ex:1-5`) and core's own guard on this same optional CRM
  # module (`phoenix_kit_web/live/users/user_details.ex:16,19`); `andi_available?/0`
  # below gates every actual call at runtime.
  @compile {:no_warn_undefined, Andi.CRMBridge}

  # Not part of `use PhoenixKitWeb, :live_view`'s auto-imports (see
  # `user_details.ex:12-14`) — explicit import needed for the Orders tab's
  # row-link overlay.
  import PhoenixKitCRM.Web.Components.TabIntro, only: [tab_intro: 1]
  import PhoenixKitCRM.Web.InteractionHelpers, only: [tz_offset: 1]
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{Activity, Attachments, Contacts, Paths}
  alias PhoenixKitCRM.PubSub, as: CRMPubSub
  alias PhoenixKitCRM.Schemas.Contact
  alias PhoenixKitCRM.Web.{EventsComponent, InteractionsComponent, MediaComponent}
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, show_avatar_picker: false, avatar_folder_uuid: nil)}

  @impl true
  def handle_params(params, _uri, socket) do
    case Contacts.get_contact(params["uuid"]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Contact not found"))
         |> push_navigate(to: Paths.contacts())}

      contact ->
        storage_enabled = storage_enabled?()
        comments_enabled = comments_available?()
        andi_available = andi_available?()

        tab =
          if params["tab"] in valid_tabs(storage_enabled, comments_enabled, andi_available),
            do: params["tab"],
            else: "overview"

        contact_orders = load_contact_orders(andi_available, tab, contact)

        {:noreply,
         socket
         |> maybe_subscribe(contact.uuid)
         |> assign(:contact, contact)
         |> assign(:tab, tab)
         |> assign(:storage_enabled, storage_enabled)
         |> assign(:comments_enabled, comments_enabled)
         |> assign(:andi_available, andi_available)
         |> assign(:contact_orders, contact_orders)
         |> assign(:avatar_url, Attachments.avatar_url(contact))
         |> assign(:membership, Contacts.primary_membership(contact))
         |> assign(:tz_offset, tz_offset(socket.assigns[:phoenix_kit_current_user]))
         |> assign(:page_title, Contact.display_name(contact))
         |> assign(:page_section, gettext("Contacts"))
         |> assign(:page_section_path, Paths.contacts())}
    end
  end

  # Subscribe once (per contact) to this contact's interaction feed so any
  # add/edit/delete by anyone — including from another open tab — pushes a live
  # refresh. Tab switches re-run handle_params but keep the same contact, so the
  # guard avoids a duplicate subscription; navigating to a different contact is a
  # fresh LiveView, which cleans up the old subscription on its own.
  defp maybe_subscribe(socket, contact_uuid) do
    current = socket.assigns[:subscribed_uuid]

    if connected?(socket) and current != contact_uuid do
      # Drop a prior subscription if this process ever switches contact in place
      # (defensive — navigating today is a fresh LiveView, which cleans up its
      # own subscriptions). Only record the uuid once the subscribe succeeds, so
      # a transient failure is retried on the next handle_params.
      if current, do: CRMPubSub.unsubscribe(CRMPubSub.topic_contact_interactions(current))

      case CRMPubSub.subscribe(CRMPubSub.topic_contact_interactions(contact_uuid)) do
        :ok -> assign(socket, :subscribed_uuid, contact_uuid)
        _ -> socket
      end
    else
      socket
    end
  end

  @impl true
  # A CRM interaction touching this contact changed somewhere — refresh the
  # feed if the Interactions tab is open (the component reloads in update/2).
  # When it's not open, the component remounts fresh on the next switch, so
  # there's nothing to do.
  def handle_info({:crm, _event, _payload}, socket) do
    # Reload whichever feed-bearing tab is open. Interactions are the main
    # activity driver, so the Events tab live-refreshes off the same signal.
    if socket.assigns[:contact] do
      case socket.assigns[:tab] do
        "interactions" ->
          # A fresh token forces the component to reload its feed (its update/2
          # only re-queries on a contact change or a new refresh token).
          send_update(InteractionsComponent,
            id: "crm-interactions-#{socket.assigns.contact.uuid}",
            refresh_token: System.unique_integer([:monotonic])
          )

        "events" ->
          send_update(EventsComponent, id: "crm-events-#{socket.assigns.contact.uuid}")

        # The Files tab rolls up the files attached to this contact's
        # interactions; an interaction created with attachments or deleted
        # (which purges its folder) changes that list and its count.
        "files" ->
          send_update(MediaComponent,
            id: "crm-files-#{socket.assigns.contact.uuid}",
            refresh_token: System.unique_integer([:monotonic])
          )

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  # Media component (a LiveComponent, so it routes user-facing flash + avatar
  # refreshes up to this host LiveView).
  def handle_info({:put_flash, kind, msg}, socket), do: {:noreply, put_flash(socket, kind, msg)}

  def handle_info({:avatar_changed}, socket) do
    contact = Contacts.get_contact(socket.assigns.contact.uuid) || socket.assigns.contact

    {:noreply,
     socket |> assign(:contact, contact) |> assign(:avatar_url, Attachments.avatar_url(contact))}
  end

  # The header avatar picker (a MediaSelectorModal with no `notify`) delivers its
  # result here as a process message; the Files/Images tab pickers notify their
  # own component instead, so they don't land here.
  def handle_info({:media_selected, [uuid | _]}, socket) when is_binary(uuid) do
    case Attachments.set_avatar(:contact, socket.assigns.contact, uuid) do
      {:ok, _} ->
        log_avatar(socket, "set")
        send(self(), {:avatar_changed})

      _ ->
        :ok
    end

    {:noreply, assign(socket, :show_avatar_picker, false)}
  end

  def handle_info({:media_selected, _}, socket),
    do: {:noreply, assign(socket, :show_avatar_picker, false)}

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, assign(socket, :show_avatar_picker, false)}

  def handle_info(msg, socket) do
    Logger.debug("[CRM] ContactShowLive ignoring message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Open the avatar picker scoped to the contact's Images folder (so it suggests
  # existing images and uploads land in the Images tab).
  @impl true
  def handle_event("edit_avatar", _params, socket) do
    cond do
      not socket.assigns.storage_enabled ->
        {:noreply, socket}

      Contact.trashed?(socket.assigns.contact) ->
        {:noreply,
         put_flash(socket, :error, gettext("Restore this contact before changing its photo."))}

      true ->
        actor = current_user_uuid(socket.assigns)

        case Attachments.ensure_folder(:contact, socket.assigns.contact.uuid, :images, actor) do
          {:ok, folder_uuid} ->
            {:noreply, assign(socket, avatar_folder_uuid: folder_uuid, show_avatar_picker: true)}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not open the image picker."))}
        end
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    case Attachments.clear_avatar(socket.assigns.contact) do
      {:ok, _} ->
        log_avatar(socket, "removed")
        send(self(), {:avatar_changed})
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the photo."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp log_avatar(socket, verb) do
    Activity.log("crm.contact_avatar_#{verb}",
      actor_uuid: current_user_uuid(socket.assigns),
      resource_type: "crm_contact",
      resource_uuid: socket.assigns.contact.uuid,
      metadata: %{}
    )
  end

  # Tab definitions drive both the nav and `valid_tabs/3` (deep-link clamp).
  # Orders appears only when the host app's `Andi.CRMBridge` is available;
  # Files + Images only when core Storage is enabled; Comments only when the
  # comments module is enabled.
  # nav_tabs maps rather than tuples: positional tuples cannot grow a
  # :badge or link key without breaking every consumer at once. Kept
  # uuid-free so valid_tabs/3 shares the same list; nav_tab_defs/4 adds the
  # patch URLs for the strip.
  defp tab_defs(storage_enabled?, comments_enabled?, andi_available?) do
    [
      %{id: "overview", label: gettext("Overview"), icon: "hero-identification"},
      %{id: "interactions", label: gettext("Interactions"), icon: "hero-chat-bubble-left-right"}
    ]
    |> maybe_concat(andi_available?, [
      %{id: "orders", label: gettext("Orders"), icon: "hero-clipboard-document-list"}
    ])
    |> maybe_concat(storage_enabled?, [
      %{id: "files", label: gettext("Files"), icon: "hero-document"},
      %{id: "images", label: gettext("Images"), icon: "hero-photo"}
    ])
    |> Kernel.++([%{id: "events", label: gettext("Events"), icon: "hero-clock"}])
    |> maybe_concat(comments_enabled?, [
      %{id: "comments", label: gettext("Comments"), icon: "hero-chat-bubble-bottom-center-text"}
    ])
  end

  defp nav_tab_defs(uuid, storage_enabled?, comments_enabled?, andi_available?) do
    tab_defs(storage_enabled?, comments_enabled?, andi_available?)
    |> Enum.map(&Map.put(&1, :patch, tab_path(uuid, &1.id)))
  end

  defp maybe_concat(list, true, extra), do: list ++ extra
  defp maybe_concat(list, false, _extra), do: list

  defp valid_tabs(storage_enabled?, comments_enabled?, andi_available?),
    do: Enum.map(tab_defs(storage_enabled?, comments_enabled?, andi_available?), & &1.id)

  defp tab_path(uuid, "overview"), do: Paths.contact(uuid)
  defp tab_path(uuid, tab), do: Paths.contact(uuid) <> "?tab=#{tab}"

  defp storage_enabled? do
    Storage.enabled?()
  rescue
    _ -> false
  end

  defp comments_available? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end

  # Whether the host app's order bridge is present. `Andi.CRMBridge` is not a
  # dependency of this package (Andi depends on CRM, never the reverse), so
  # this is `false` — safely, not an error — whenever this module runs outside
  # the Andi app (this package's own test suite, `mix docs`, etc.).
  defp andi_available? do
    Code.ensure_loaded?(Andi.CRMBridge) and
      function_exported?(Andi.CRMBridge, :orders_for_contact, 1)
  rescue
    _ -> false
  end

  # Only the Orders tab needs the host's orders — every other tab switch
  # re-runs `handle_params/3`, and querying the host on each one buys nothing.
  #
  # Rescued for the same reason every other soft-dependency call here is
  # (`storage_enabled?/0`, `comments_available?/0`, `StaffLink`): the bridge is
  # the host's code, outside this package's tests and its release cycle. An
  # exception raised in there must cost the Orders tab its rows, not take down
  # a contact profile whose other five tabs never touch it.
  defp load_contact_orders(true, "orders", contact) do
    Andi.CRMBridge.orders_for_contact(contact)
  rescue
    e ->
      Logger.warning("[CRM] Andi.CRMBridge.orders_for_contact failed: #{Exception.message(e)}")
      []
  end

  defp load_contact_orders(_andi_available?, _tab, _contact), do: []

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <div class="flex items-center gap-3">
          <.contact_avatar url={@avatar_url} contact={@contact} storage_enabled={@storage_enabled} />
          <div>
            <div class="flex items-center gap-2">
              <.status_badge status={@contact.status} size={:sm} />
              <span :if={@contact.user_uuid} class="badge badge-success badge-sm gap-1">
                <.icon name="hero-key-mini" class="w-3 h-3" /> {gettext("Login")}
              </span>
            </div>
            <div :if={@membership} class="text-sm text-base-content/60 mt-1">
              <.link navigate={Paths.company(@membership.company_uuid)} class="link link-hover">
                {membership_company(@membership)}
              </.link>{role_dept_suffix(@membership)}
            </div>
          </div>
        </div>
        <.link navigate={Paths.contact_edit(@contact.uuid)} class="btn btn-outline btn-sm">
          <.icon name="hero-pencil-square" class="w-4 h-4" /> {gettext("Edit")}
        </.link>
      </div>

      <%!-- Core's <.nav_tabs> border variant. patch URLs are built by
           tab_path/2 (already prefixed) — nav_tabs passes them verbatim. --%>
      <.nav_tabs
        variant={:border}
        active_tab={@tab}
        tabs={nav_tab_defs(@contact.uuid, @storage_enabled, @comments_enabled, @andi_available)}
      />

      <div :if={@tab == "overview"} class="card bg-base-100 shadow-sm">
        <div class="card-body grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-3">
          <.field label={gettext("Email")} value={@contact.email} />
          <.field label={gettext("Phone")} value={@contact.phone} />
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">{gettext("Company")}</div>
            <div class="text-sm">
              <.link
                :if={@membership}
                navigate={Paths.company(@membership.company_uuid)}
                class="link link-hover"
              >
                {membership_company(@membership)}
              </.link>
              <span :if={!@membership}>—</span>
            </div>
          </div>
          <.field label={gettext("Role in company")} value={@membership && @membership.role_in_company} />
          <.field label={gettext("Department / team")} value={@membership && @membership.department} />
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">{gettext("Login account")}</div>
            <div class="text-sm">
              <.link
                :if={@contact.user_uuid}
                navigate={Paths.user_view(@contact.user_uuid)}
                class="link link-hover"
              >
                {gettext("View login account")}
              </.link>
              <span :if={!@contact.user_uuid}>{gettext("None")}</span>
            </div>
          </div>
          <div class="sm:col-span-2"><.field label={gettext("Notes")} value={@contact.notes} /></div>
        </div>
      </div>

      <div :if={@tab == "interactions"}>
        <.live_component
          module={InteractionsComponent}
          id={"crm-interactions-#{@contact.uuid}"}
          contact={@contact}
          current_user_uuid={current_user_uuid(assigns)}
          current_user_name={current_user_name(assigns)}
          phoenix_kit_current_user={@phoenix_kit_current_user}
          tz_offset={@tz_offset}
        />
      </div>

      <div :if={@tab == "orders"}>
        <.empty_state
          :if={@contact_orders == []}
          icon="hero-clipboard-document-list"
          title={gettext("No orders yet")}
          description={gettext("Orders placed by this contact's linked login account will appear here.")}
        />
        <.table_default :if={@contact_orders != []}>
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Order")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Created")}</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row
              :for={order <- @contact_orders}
              class="relative transform-gpu cursor-pointer"
            >
              <%!-- Every field, including the link target, comes from the host
                   bridge. This package is host-agnostic: it must not know where
                   a given application keeps its orders, or which column holds
                   the number. A route rename in the host would otherwise ship a
                   dead link here that nothing can catch. --%>
              <.table_default_cell class="font-medium">
                <.row_link
                  navigate={order.path}
                  label={gettext("Open order #%{number}", number: order.number)}
                />
                #{order.number}
              </.table_default_cell>
              <.table_default_cell class="text-base-content/70">
                {Calendar.strftime(order.inserted_at, "%Y-%m-%d")}
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
      </div>

      <div :if={@tab == "events"} class="flex flex-col gap-3">
        <.tab_intro text={
          gettext("What happened to this record — edits, links, role changes — as recorded automatically. Nothing is added here by hand.")
        } />
        <.live_component
          module={EventsComponent}
          id={"crm-events-#{@contact.uuid}"}
          resource_type="crm_contact"
          resource_uuid={@contact.uuid}
          tz_offset={@tz_offset}
        />
      </div>

      <div :if={@tab == "files"} class="flex flex-col gap-3">
        <.tab_intro text={
          gettext("Documents kept on this contact, added here — plus, below them, the files attached to this contact's interactions.")
        } />
        <.live_component
          module={MediaComponent}
          id={"crm-files-#{@contact.uuid}"}
          kind={:files}
          resource_type={:contact}
          resource={@contact}
          phoenix_kit_current_user={@phoenix_kit_current_user}
        />
      </div>

      <div :if={@tab == "images"}>
        <.live_component
          module={MediaComponent}
          id={"crm-images-#{@contact.uuid}"}
          kind={:images}
          resource_type={:contact}
          resource={@contact}
          phoenix_kit_current_user={@phoenix_kit_current_user}
        />
      </div>

      <div :if={@tab == "comments"} class="flex flex-col gap-3">
        <.tab_intro text={gettext("Notes about this person, written here.")} />
        <.live_component
          module={PhoenixKitComments.Web.CommentsComponent}
          id={"crm-contact-comments-#{@contact.uuid}"}
          resource_type="crm_contact"
          resource_uuid={@contact.uuid}
          current_user={@phoenix_kit_current_user}
        />
      </div>

      <%!-- Header-avatar picker (Images folder; no `notify` → result lands in
           this LV's handle_info). --%>
      <.live_component
        :if={@show_avatar_picker}
        module={MediaSelectorModal}
        id={"crm-contact-avatar-#{@contact.uuid}"}
        show={true}
        mode={:single}
        file_type_filter={:image}
        browse={true}
        selected_uuids={Enum.reject([Attachments.avatar_uuid(@contact)], &is_nil/1)}
        scope_folder_id={@avatar_folder_uuid}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />
    </div>
    """
  end

  # Circular contact avatar (header) — click to set/change (Storage required),
  # hover to remove when set. Image if set, else initials.
  attr(:url, :string, default: nil)
  attr(:contact, :map, required: true)
  attr(:storage_enabled, :boolean, default: false)

  defp contact_avatar(assigns) do
    ~H"""
    <div class="relative shrink-0 group">
      <button
        type="button"
        phx-click="edit_avatar"
        disabled={!@storage_enabled}
        class="block w-12 h-12 rounded-full overflow-hidden ring-1 ring-base-300 bg-base-300 disabled:cursor-default"
        aria-label={gettext("Change photo")}
      >
        <img :if={@url} src={@url} alt="" class="w-full h-full object-cover" />
        <span
          :if={!@url}
          class="flex items-center justify-center w-full h-full text-lg font-semibold text-base-content/60"
        >
          {avatar_initials(@contact)}
        </span>
        <span
          :if={@storage_enabled}
          class="absolute inset-0 hidden group-hover:flex items-center justify-center bg-black/40 text-white rounded-full"
        >
          <.icon name="hero-camera" class="w-4 h-4" />
        </span>
      </button>
      <button
        :if={@storage_enabled and @url}
        type="button"
        phx-click="remove_avatar"
        data-confirm={gettext("Remove this photo?")}
        class="absolute -top-1 -right-1 btn btn-xs btn-circle btn-error opacity-0 group-hover:opacity-100 transition"
        aria-label={gettext("Remove photo")}
      >
        <.icon name="hero-x-mark" class="w-3 h-3" />
      </button>
    </div>
    """
  end

  defp avatar_initials(contact) do
    contact
    |> Contact.display_name()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)

  defp field(assigns) do
    ~H"""
    <div>
      <div class="text-xs uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class="text-sm">{@value || "—"}</div>
    </div>
    """
  end

  defp membership_company(%{company: %{name: name}}) when is_binary(name), do: name
  defp membership_company(_), do: nil

  # " · Role · Dept" suffix after the (linked) company name, or "" when absent.
  defp role_dept_suffix(membership) do
    case [membership.role_in_company, membership.department] |> Enum.reject(&(&1 in [nil, ""])) do
      [] -> ""
      parts -> " · " <> Enum.join(parts, " · ")
    end
  end

  defp current_user_uuid(assigns) do
    case assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  # Display name for the "Add me" party shortcut — full name, else email.
  defp current_user_name(assigns) do
    case assigns[:phoenix_kit_current_user] do
      %{} = user ->
        case User.full_name(user) do
          name when is_binary(name) and name != "" -> name
          _ -> user.email
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
