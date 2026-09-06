defmodule PhoenixKitCRM.Web.CompanyShowLive do
  @moduledoc """
  Show page for a CRM company. Tabs: Overview (identity block — logo picker,
  status, role badges — plus details), Members, Interactions (a composer for
  company-anchored interactions plus a merged feed of the members' own,
  behind an All | Company | People filter), and Events always; Catalogue when
  the catalogue module is enabled; Files + Images when core Storage is
  enabled; Comments when the comments module is enabled. There is no in-body
  header band: the name lives in the layout header and Edit rides its
  `page_action` chip.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext
  # Forwards the comment composer's {:leaf_changed, …} into CommentsComponent.
  use PhoenixKitComments.Embed

  require Logger

  # Guarded soft-dependency on the catalogue for the Catalogue tab — same idiom
  # as the contact page's Andi.CRMBridge Orders tab and `StaffLink`. CRM has no
  # compile-time dependency on the catalogue, so a plain qualified call would
  # warn under --warnings-as-errors; `catalogue_available?/0` gates every call.
  @compile {:no_warn_undefined,
            [
              PhoenixKitCatalogue,
              PhoenixKitCatalogue.Catalogue,
              PhoenixKitCatalogue.Web.Components
            ]}

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Activity, Attachments, Companies, PartyRoles, Paths}
  alias PhoenixKitCRM.PubSub, as: CRMPubSub
  alias PhoenixKitCRM.Schemas.{Company, Contact}
  alias PhoenixKitCRM.Web.Components.MirrorPanel
  alias PhoenixKitCRM.Web.{EventsComponent, InteractionsComponent, MediaComponent}

  import PhoenixKitCRM.Web.Components.TabIntro, only: [tab_intro: 1]

  import PhoenixKitCRM.Web.InteractionHelpers,
    only: [viewer_tz: 1, current_user_uuid: 1, current_user_name: 1]

  import PhoenixKitCRM.Web.PartyRoleHelpers, only: [role_label: 1, role_badge_class: 1]
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  # `PhoenixKitCatalogue.Catalogue.PubSub`'s topic — a string contract, so no
  # compile-time dependency on the (optional) catalogue package is needed.
  @catalogue_topic "phoenix_kit_catalogue"

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         show_avatar_picker: false,
         avatar_folder_uuid: nil,
         subscribed_company: nil,
         subscribed_contacts: MapSet.new(),
         subscribed_catalogue: false
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    case Companies.get_company(params["uuid"]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Company not found"))
         |> push_navigate(to: Paths.companies())}

      company ->
        storage_enabled = storage_enabled?()
        comments_enabled = comments_available?()
        catalogue_enabled = catalogue_available?()

        tab =
          if params["tab"] in valid_tabs(storage_enabled, comments_enabled, catalogue_enabled),
            do: params["tab"],
            else: "overview"

        {:noreply,
         socket
         # Subscribe BEFORE the reads below: a write committed between the
         # read and the subscription would otherwise be missed. Member
         # interaction feeds need the roster, so that list is the first
         # read — then those topics, then the rest of the page.
         |> subscribe_live(company, catalogue_enabled)
         |> assign(:company, company)
         |> assign(:tab, tab)
         |> assign(:storage_enabled, storage_enabled)
         |> assign(:comments_enabled, comments_enabled)
         |> assign(:catalogue_enabled, catalogue_enabled)
         |> assign(:memberships, Companies.list_memberships(company.uuid))
         |> sync_member_subscriptions()
         |> assign_new(:show_catalogue_columns, fn -> false end)
         |> assign_new(:catalogue_columns, fn -> catalogue_default_columns() end)
         |> assign_new(:catalogue_column_catalog, fn -> catalogue_column_catalog() end)
         |> assign_new(:column_picker_available, fn -> column_picker_available?() end)
         |> assign_catalogue(catalogue_enabled, company)
         |> assign(:avatar_url, Attachments.avatar_url(company))
         |> assign(:tz, viewer_tz(socket.assigns[:phoenix_kit_current_user]))
         |> assign(
           :company_roles,
           Map.get(PartyRoles.active_roles_map("company", [company.uuid]), company.uuid, [])
         )
         |> assign(:page_title, Company.display_name(company))
         |> assign(:page_section, gettext("Companies"))
         |> assign(:page_section_path, Paths.companies())
         # Edit lives in the layout's breadcrumb action chip — the in-body
         # header band it used to occupy is gone (it held only the logo, the
         # status badge and this button once the name moved into the header).
         |> assign(:page_action, %{
           icon: "hero-pencil-square",
           label: gettext("Edit company"),
           navigate: Paths.company_edit(company.uuid)
         })
         |> assign(:mirror_user, mirror_user(company))}
    end
  end

  # ── Live refresh ─────────────────────────────────────────────────
  #
  # Everything this page shows is derived from records other pages and
  # sessions change: the member roster (contact edit page, contact trash /
  # restore / delete), the interactions rollup and Events tab (a member's
  # interactions, on the contact page), and the Catalogue tab (the catalogue
  # module's supplier rows). Each has a topic; subscribe once per company,
  # and once per member contact for the interaction feeds — re-synced when
  # the roster changes, so a new member's feed is followed too.
  defp subscribe_live(socket, company, catalogue_enabled?) do
    if connected?(socket) do
      socket
      |> subscribe_company(company)
      |> sync_catalogue_subscription(catalogue_enabled?)
    else
      socket
    end
  end

  # Switching company inside one process (a patch to another uuid) must
  # drop the old company's topic, or it keeps refreshing this page for the
  # life of the socket. The member feeds are re-synced once the new roster
  # is loaded (`sync_member_subscriptions/1`).
  defp subscribe_company(socket, company) do
    previous = socket.assigns.subscribed_company

    if previous != company.uuid do
      if previous do
        CRMPubSub.unsubscribe(CRMPubSub.topic_company(previous))
        CRMPubSub.unsubscribe(CRMPubSub.topic_company_interactions(previous))
      end

      CRMPubSub.subscribe(CRMPubSub.topic_company(company.uuid))
      # The company's OWN interaction feed (company-anchored writes) — member
      # interactions arrive on the per-member topics synced below.
      CRMPubSub.subscribe(CRMPubSub.topic_company_interactions(company.uuid))
      assign(socket, :subscribed_company, company.uuid)
    else
      socket
    end
  end

  # The catalogue topic is process-wide, not per company, and lives on the
  # HOST PubSub (the catalogue broadcasts through PhoenixKit.PubSubHelper).
  # Reconciled on every request so enabling the module mid-session
  # subscribes and disabling it unsubscribes.
  defp sync_catalogue_subscription(socket, enabled?) do
    case {enabled?, socket.assigns.subscribed_catalogue} do
      {true, false} ->
        CRMPubSub.subscribe_host(@catalogue_topic)
        assign(socket, :subscribed_catalogue, true)

      {false, true} ->
        CRMPubSub.unsubscribe_host(@catalogue_topic)
        assign(socket, :subscribed_catalogue, false)

      _ ->
        socket
    end
  end

  defp sync_member_subscriptions(socket) do
    if connected?(socket) do
      already = socket.assigns.subscribed_contacts
      wanted = MapSet.new(socket.assigns.memberships, & &1.contact_uuid)

      wanted
      |> MapSet.difference(already)
      |> Enum.each(&CRMPubSub.subscribe(CRMPubSub.topic_contact_interactions(&1)))

      already
      |> MapSet.difference(wanted)
      |> Enum.each(&CRMPubSub.unsubscribe(CRMPubSub.topic_contact_interactions(&1)))

      assign(socket, :subscribed_contacts, wanted)
    else
      socket
    end
  end

  # The roster changed (a contact joined, left, was trashed/restored/deleted
  # or renamed): reload it, follow the new set of member feeds, and refresh
  # the tab that is open.
  defp refresh_roster(socket) do
    company = socket.assigns.company

    socket
    |> assign(:memberships, Companies.list_memberships(company.uuid))
    |> assign(:mirror_user, mirror_user(company))
    |> sync_member_subscriptions()
    |> refresh_open_tab()
  end

  defp refresh_open_tab(socket) do
    uuid = socket.assigns.company.uuid

    case socket.assigns.tab do
      "interactions" ->
        send_update(InteractionsComponent,
          id: "crm-company-interactions-#{uuid}",
          refresh_token: System.unique_integer([:monotonic])
        )

      "events" ->
        send_update(EventsComponent, id: "crm-company-events-#{uuid}")

      _ ->
        :ok
    end

    socket
  end

  @impl true
  # The media component (a LiveComponent) routes flash + logo refreshes up here.
  def handle_info({:put_flash, kind, msg}, socket), do: {:noreply, put_flash(socket, kind, msg)}

  def handle_info({:avatar_changed}, socket) do
    company = Companies.get_company(socket.assigns.company.uuid) || socket.assigns.company

    {:noreply,
     socket |> assign(:company, company) |> assign(:avatar_url, Attachments.avatar_url(company))}
  end

  # Header-logo picker (a MediaSelectorModal with no `notify`) delivers its
  # result here; the Files/Images tab pickers notify their own component.
  def handle_info({:media_selected, [uuid | _]}, socket) when is_binary(uuid) do
    case Attachments.set_avatar(:company, socket.assigns.company, uuid) do
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

  # Roster events on this company's topic.
  def handle_info({:crm, event, %{contact_uuid: _}}, socket)
      when event in [:member_joined, :member_left, :member_changed] do
    {:noreply, refresh_roster(socket)}
  end

  # A member's interaction changed (per-contact feed topics): the rollup and
  # the Events tab move; the roster does not.
  def handle_info({:crm, _event, %{interaction_uuid: _}}, socket) do
    {:noreply, refresh_open_tab(socket)}
  end

  # The catalogue module's own topic: a supplier row or item changed
  # somewhere. The Catalogue tab's counts and tables are re-derived; other
  # kinds (folders, PDFs, …) carry nothing this page shows.
  # `:supplier` / `:manufacturer` / `:links` are the party rows and their
  # CRM-company links — what decides which items count as "supplied by"
  # this company at all. `:category` is a default column of
  # `party_items_table/1` (`items_supplied_by/1` preloads it).
  def handle_info({:catalogue_data_changed, kind, _uuid, _}, socket)
      when kind in [
             :item_supplier_info,
             :item,
             :catalogue,
             :category,
             :supplier,
             :manufacturer,
             :links
           ] do
    if socket.assigns.catalogue_enabled,
      do: {:noreply, assign_catalogue(socket, true, socket.assigns.company)},
      else: {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.debug("[CRM] CompanyShowLive ignoring message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Open the logo picker scoped to the company's Images folder.
  @impl true
  def handle_event("edit_avatar", _params, socket) do
    cond do
      not socket.assigns.storage_enabled ->
        {:noreply, socket}

      Company.trashed?(socket.assigns.company) ->
        {:noreply,
         put_flash(socket, :error, gettext("Restore this company before changing its logo."))}

      true ->
        case Attachments.ensure_folder(
               :company,
               socket.assigns.company.uuid,
               :images,
               actor_uuid(socket)
             ) do
          {:ok, folder_uuid} ->
            {:noreply, assign(socket, avatar_folder_uuid: folder_uuid, show_avatar_picker: true)}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not open the image picker."))}
        end
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    case Attachments.clear_avatar(socket.assigns.company) do
      {:ok, _} ->
        log_avatar(socket, "removed")
        send(self(), {:avatar_changed})
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the logo."))}
    end
  end

  # Core's column_settings_modal event contract. It is pure presentation — the
  # consumer owns the catalog, the selection and persistence — so these four
  # plus the close are all it asks for.
  def handle_event("show_column_modal", _params, socket),
    do: {:noreply, assign(socket, :show_catalogue_columns, true)}

  def handle_event("hide_column_modal", _params, socket),
    do: {:noreply, assign(socket, :show_catalogue_columns, false)}

  def handle_event("add_column", %{"column_id" => id}, socket) do
    {:noreply, put_catalogue_columns(socket, socket.assigns.catalogue_columns ++ [id])}
  end

  def handle_event("remove_column", %{"column_id" => id}, socket) do
    {:noreply, put_catalogue_columns(socket, socket.assigns.catalogue_columns -- [id])}
  end

  def handle_event("reorder_columns", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    {:noreply, put_catalogue_columns(socket, ids)}
  end

  def handle_event("reset_columns", _params, socket),
    do: {:noreply, put_catalogue_columns(socket, catalogue_default_columns())}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Only ids the catalogue actually offers, so a forged payload cannot inject
  # a column name into the table.
  defp put_catalogue_columns(socket, ids) do
    catalog = catalogue_column_catalog()
    # `&1[:id]` rather than `&1.id`: the catalog crosses a module boundary, and
    # a shape change there should narrow the picker, not raise in mount.
    known = catalog |> Enum.map(&(is_map(&1) && &1[:id])) |> Enum.reject(&(!&1)) |> MapSet.new()

    socket
    # Rendered per row; resolving it once per mount instead of once per render
    # keeps the apply/3 off the hot path.
    |> assign(:catalogue_column_catalog, catalog)
    |> assign(:column_picker_available, column_picker_available?())
    |> assign(:catalogue_columns, ids |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.uniq())
  end

  defp column_picker_available? do
    Code.ensure_loaded?(PhoenixKitWeb.Components.Core.ColumnSettings) and
      function_exported?(PhoenixKitWeb.Components.Core.ColumnSettings, :column_settings_modal, 1)
  end

  defp catalogue_column_catalog do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCatalogue.Web.Components, :party_items_columns, [])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp catalogue_default_columns do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCatalogue.Web.Components, :party_items_default_columns, [])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp log_avatar(socket, verb) do
    Activity.log("crm.company_avatar_#{verb}",
      actor_uuid: actor_uuid(socket),
      resource_type: "crm_company",
      resource_uuid: socket.assigns.company.uuid,
      metadata: %{}
    )
  end

  # nav_tabs maps rather than tuples — see contact_show_live's tab_defs.
  # uuid-free so valid_tabs/3 shares it; nav_tab_defs/4 adds patch URLs.
  defp tab_defs(storage_enabled?, comments_enabled?, catalogue_enabled?) do
    [
      %{id: "overview", label: gettext("Overview"), icon: "hero-identification"},
      %{id: "members", label: gettext("Members"), icon: "hero-users"},
      %{id: "interactions", label: gettext("Interactions"), icon: "hero-chat-bubble-left-right"},
      %{id: "events", label: gettext("Events"), icon: "hero-clock"}
    ]
    |> maybe_concat(catalogue_enabled?, [
      %{id: "catalogue", label: gettext("Catalogue"), icon: "hero-rectangle-stack"}
    ])
    |> maybe_concat(storage_enabled?, [
      %{id: "files", label: gettext("Files"), icon: "hero-document"},
      %{id: "images", label: gettext("Images"), icon: "hero-photo"}
    ])
    |> maybe_concat(comments_enabled?, [
      %{id: "comments", label: gettext("Comments"), icon: "hero-chat-bubble-bottom-center-text"}
    ])
  end

  defp nav_tab_defs(uuid, storage_enabled?, comments_enabled?, catalogue_enabled?) do
    tab_defs(storage_enabled?, comments_enabled?, catalogue_enabled?)
    |> Enum.map(&Map.put(&1, :patch, tab_path(uuid, &1.id)))
  end

  defp maybe_concat(list, true, extra), do: list ++ extra
  defp maybe_concat(list, false, _extra), do: list

  defp valid_tabs(storage_enabled?, comments_enabled?, catalogue_enabled?),
    do: Enum.map(tab_defs(storage_enabled?, comments_enabled?, catalogue_enabled?), & &1.id)

  defp tab_path(uuid, "overview"), do: Paths.company(uuid)
  defp tab_path(uuid, tab), do: Paths.company(uuid) <> "?tab=#{tab}"

  defp storage_enabled? do
    Storage.enabled?()
  rescue
    _ -> false
  end

  # ── Catalogue tab ───────────────────────────────────────────────────
  # Suppliers and manufacturers are CRM companies now, so this page is the
  # only place they exist — which makes "what do they actually supply?" a
  # question it has to be able to answer. The catalogue keeps the per-item
  # sourcing facts; this reads them, never writes them.

  # Installed AND switched on, matching how the Comments tab gates itself.
  # Checking only that the module is loaded would leave this tab showing after
  # an admin disabled the catalogue — its own admin tabs would vanish from the
  # nav while this one went on querying it.
  # The tab follows the company's roles, not a fixed layout: a company that
  # only supplies has no business being shown an empty "Manufactured items"
  # list. The exception is leftover data — a role revoked while items still
  # reference it — which is surfaced rather than hidden, because that is the
  # inconsistency someone needs to see.
  defp assign_catalogue(socket, false, _company) do
    assign(socket, %{
      supplied_items: [],
      manufactured_items: [],
      show_supplied: false,
      show_manufactured: false,
      orphan_supplied: false,
      orphan_manufactured: false
    })
  end

  defp assign_catalogue(socket, true, company) do
    supplied = supplied_items(company)
    manufactured = manufactured_items(company)
    supplier? = holds_role?(company, "supplier")
    manufacturer? = holds_role?(company, "manufacturer")

    assign(socket, %{
      supplied_items: supplied,
      manufactured_items: manufactured,
      show_supplied: supplier? or supplied != [],
      show_manufactured: manufacturer? or manufactured != [],
      # Items still pointing here after the role was taken away.
      orphan_supplied: not supplier? and supplied != [],
      orphan_manufactured: not manufacturer? and manufactured != []
    })
  end

  # The catalogue renders its own items — image column, card/table toggle,
  # price and status formatting — so an embedded list matches the catalogue's
  # own instead of drifting from it. Called through `apply/3` because CRM has
  # no compile-time dependency on the catalogue; `party_items_table/1` exists
  # on that side precisely so this stays a two-key contract.
  defp catalogue_items_table([], _id, _columns), do: nil

  defp catalogue_items_table(items, id, columns) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCatalogue.Web.Components, :party_items_table, [
      %{items: items, id: id, columns: Enum.map(columns, &String.to_existing_atom/1)}
    ])
  rescue
    error ->
      Logger.warning(
        "CRM: could not render the catalogue item table: #{Exception.message(error)}"
      )

      # NOT nil: the heading above carries a count badge, so rendering nothing
      # left "3" sitting over blank space with no hint that anything failed.
      table_unavailable()
  catch
    :exit, _ -> nil
  end

  defp table_unavailable do
    assigns = %{}

    ~H"""
    <p class="text-sm text-base-content/50 italic">
      {gettext("These items could not be displayed. The catalogue module may be unavailable.")}
    </p>
    """
  end

  defp holds_role?(company, role) do
    PartyRoles.has_role?(company, role)
  rescue
    _ -> false
  end

  defp catalogue_available? do
    # Every hop is probed before it is taken: `enabled?/0` goes through
    # `apply/3` for the same reason the calls below it do — a static remote
    # call into an optional dependency is an `unknown_function` to dialyzer
    # and an `UndefinedFunctionError` at runtime on an install without the
    # catalogue, which the rescue would then silently turn into "no tab".
    Code.ensure_loaded?(PhoenixKitCatalogue) and
      function_exported?(PhoenixKitCatalogue, :enabled?, 0) and
      catalogue_enabled?() and
      Code.ensure_loaded?(PhoenixKitCatalogue.Catalogue) and
      function_exported?(PhoenixKitCatalogue.Catalogue, :items_supplied_by, 1)
  rescue
    _ -> false
  end

  # Its own function so the credo exemption can sit on the apply itself — inside
  # the `and` chain above the formatter pushes the comment away from the line.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp catalogue_enabled?, do: apply(PhoenixKitCatalogue, :enabled?, [])

  defp supplied_items(company) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCatalogue.Catalogue, :items_supplied_by, [company.uuid])
  rescue
    error ->
      Logger.warning("CRM: could not load supplied items: #{Exception.message(error)}")
      []
  catch
    :exit, _ -> []
  end

  defp manufactured_items(company) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(PhoenixKitCatalogue.Catalogue, :items_manufactured_by, [company.uuid])
  rescue
    error ->
      Logger.warning("CRM: could not load manufactured items: #{Exception.message(error)}")
      []
  catch
    :exit, _ -> []
  end

  defp comments_available? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end

  # The linked mirror user, if any — read-only status for the Overview tab
  # (Task J). All editing/linking lives on the edit form (Task G). `nil`
  # covers both "never linked" and an orphaned `user_uuid` (the referenced
  # user no longer exists); the UI treats them the same, as "None".
  defp mirror_user(%Company{user_uuid: nil}), do: nil
  defp mirror_user(%Company{user_uuid: uuid}), do: Auth.get_user(uuid)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <%!-- No in-body header band (boss, via the todo): the name lives in the
           layout header, Edit in its breadcrumb action chip, and the identity
           block (logo / status / roles) opens the Overview tab. The page
           starts at the tabs. --%>
      <%!-- Core's <.nav_tabs> border variant. patch URLs are built by
           tab_path/2 (already prefixed) — nav_tabs passes them verbatim. --%>
      <.nav_tabs
        variant={:border}
        active_tab={@tab}
        tabs={nav_tab_defs(@company.uuid, @storage_enabled, @comments_enabled, @catalogue_enabled)}
      />

      <div :if={@tab == "overview"} class="card bg-base-100 shadow-sm">
        <div class="card-body grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-3">
          <div class="sm:col-span-2 flex items-center gap-3 flex-wrap">
            <.company_logo url={@avatar_url} storage_enabled={@storage_enabled} />
            <.status_badge status={@company.status} size={:sm} />
            <span
              :for={role <- @company_roles}
              class={["badge badge-sm", role_badge_class(role)]}
            >
              {role_label(role)}
            </span>
          </div>
          <.field label={gettext("Website")} value={@company.website} />
          <.field label={gettext("Email")} value={@company.email} />
          <.field label={gettext("Phone")} value={@company.phone} />
          <.field label={gettext("Industry")} value={@company.industry} />
          <div>
            <div class="text-xs uppercase tracking-wide text-base-content/50">
              {gettext("Mirror account")}
            </div>
            <div class="text-sm">
              <.link
                :if={@mirror_user}
                navigate={Paths.user_view(@mirror_user.uuid)}
                class="link link-hover"
              >
                {MirrorPanel.display_name(@mirror_user)}
              </.link>
              <span :if={!@mirror_user}>{gettext("None")}</span>
            </div>
          </div>
          <div class="sm:col-span-2"><.field label={gettext("Address")} value={@company.address} /></div>
          <div class="sm:col-span-2"><.field label={gettext("Notes")} value={@company.notes} /></div>
        </div>
      </div>

      <div :if={@tab == "members"} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">
            <.icon name="hero-users" class="w-5 h-5" /> {gettext("Members")} ({length(@memberships)})
          </h2>

          <%!-- Membership lives on the CONTACT (its Company field), so the
               way in is the contact form — offered here preselected. --%>
          <.tab_intro text={
            gettext("The contacts whose Company is set to this one. A contact joins from its own form's Company field:")
          }>
            <:action navigate={Paths.contact_new(company_uuid: @company.uuid)}>
              <.icon name="hero-plus-small" class="w-4 h-4" /> {gettext("New contact for this company")}
            </:action>
          </.tab_intro>

          <.empty_state
            :if={@memberships == []}
            icon="hero-users"
            title={gettext("No contacts linked to this company yet.")}
            description={gettext("Add one with the link above, or set the Company field on an existing contact's edit page.")}
          />

          <ul :if={@memberships != []} class="flex flex-col divide-y divide-base-200">
            <li :for={m <- @memberships} class="flex items-center gap-3 py-2.5">
              <.member_avatar contact={m.contact} />
              <div class="flex-1 min-w-0">
                <.link
                  :if={m.contact}
                  navigate={Paths.contact(m.contact.uuid)}
                  class="font-medium link link-hover"
                >
                  {Contact.display_name(m.contact)}
                </.link>
                <span :if={!m.contact} class="font-medium">{gettext("Unknown")}</span>
                <div :if={member_role(m) != ""} class="text-xs text-base-content/60">{member_role(m)}</div>
              </div>
              <span
                :if={m.contact && m.contact.email}
                class="text-xs text-base-content/50 hidden sm:block truncate max-w-[14rem]"
              >
                {m.contact.email}
              </span>
              <span
                :if={m.contact && m.contact.user_uuid}
                class="badge badge-success badge-sm gap-1 shrink-0"
              >
                <.icon name="hero-key-mini" class="w-3 h-3" /> {gettext("Login")}
              </span>
            </li>
          </ul>
        </div>
      </div>

      <div :if={@tab == "interactions"} class="flex flex-col gap-3">
        <.tab_intro text={
          gettext(
            "Interactions with this company itself, and — under People — everything logged on its contacts. Log company-level ones here; a person's own are logged on their page."
          )
        } />
        <.live_component
          module={InteractionsComponent}
          id={"crm-company-interactions-#{@company.uuid}"}
          company={@company}
          current_user_uuid={current_user_uuid(assigns)}
          current_user_name={current_user_name(assigns)}
          phoenix_kit_current_user={@phoenix_kit_current_user}
          tz={@tz}
        />
      </div>

      <div :if={@tab == "catalogue"} class="flex flex-col gap-6">
        <%!-- The rows are the catalogue's: an item names this company as a
             supplier or manufacturer on its own form. CRM does not build
             catalogue URLs (module boundary), so this is a pointer, not a link. --%>
        <.tab_intro text={
          gettext("Items that name this company as their supplier or manufacturer. That is set on the item itself, in the catalogue, on its Suppliers and Manufacturer tab.")
        } />

        <div :if={@show_supplied or @show_manufactured} class="flex justify-end -mb-2">
          <button
            :if={@column_picker_available}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="show_column_modal"
          >
            <.icon name="hero-view-columns" class="h-4 w-4" />
            {gettext("Columns")}
          </button>
        </div>

        <%!-- Core 2.6 added this component and mix.exs pins `~> 2.0` by policy
             (narrowing it breaks deps.get for hosts on an older core), so the
             picker is guarded rather than required. Without it the table still
             renders, on its default columns. --%>
        <PhoenixKitWeb.Components.Core.ColumnSettings.column_settings_modal
          :if={@column_picker_available}
          id="crm-company-catalogue-columns"
          show={@show_catalogue_columns}
          columns={@catalogue_column_catalog}
          selected={@catalogue_columns}
        />

        <.empty_state
          :if={not @show_supplied and not @show_manufactured}
          icon="hero-rectangle-stack"
          title={gettext("Nothing in the catalogue yet")}
          variant="card"
        >
          <p class="text-sm text-base-content/60">
            {gettext(
              "Give this company the supplier or manufacturer role, then pick it when sourcing an item."
            )}
          </p>
        </.empty_state>

        <div :if={@show_supplied} class="flex flex-col gap-2">
          <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
            <.icon name="hero-truck" class="h-4 w-4" />
            {gettext("Supplied items")}
            <span class="badge badge-ghost badge-sm">{length(@supplied_items)}</span>
          </h2>

          <div :if={@orphan_supplied} class="alert alert-warning py-2">
            <.icon name="hero-exclamation-triangle" class="h-4 w-4 shrink-0" />
            <span class="text-sm">
              {gettext(
                "This company no longer has the supplier role, but items still source from it."
              )}
            </span>
          </div>

          <.empty_state
            :if={@supplied_items == []}
            icon="hero-truck"
            title={gettext("No items sourced from this company yet")}
            variant="card"
          />

          {catalogue_items_table(@supplied_items, "crm-company-supplied-#{@company.uuid}", @catalogue_columns)}
        </div>

        <div :if={@show_manufactured} class="flex flex-col gap-2">
          <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
            <.icon name="hero-wrench-screwdriver" class="h-4 w-4" />
            {gettext("Manufactured items")}
            <span class="badge badge-ghost badge-sm">{length(@manufactured_items)}</span>
          </h2>

          <div :if={@orphan_manufactured} class="alert alert-warning py-2">
            <.icon name="hero-exclamation-triangle" class="h-4 w-4 shrink-0" />
            <span class="text-sm">
              {gettext(
                "This company no longer has the manufacturer role, but items still name it as their manufacturer."
              )}
            </span>
          </div>

          <.empty_state
            :if={@manufactured_items == []}
            icon="hero-wrench-screwdriver"
            title={gettext("No items name this company as their manufacturer yet")}
            variant="card"
          />

          {catalogue_items_table(@manufactured_items, "crm-company-manufactured-#{@company.uuid}", @catalogue_columns)}
        </div>
      </div>

      <div :if={@tab == "events"} class="flex flex-col gap-3">
        <.tab_intro text={
          gettext("What happened to this record — edits, links, role changes — as recorded automatically. Nothing is added here by hand.")
        } />
        <.live_component
          module={EventsComponent}
          id={"crm-company-events-#{@company.uuid}"}
          resource_type="crm_company"
          resource_uuid={@company.uuid}
          tz={@tz}
        />
      </div>

      <div :if={@tab == "files"} class="flex flex-col gap-3">
        <.tab_intro text={gettext("Documents kept on this company. Add them here with the Add files button.")} />
        <.live_component
          module={MediaComponent}
          id={"crm-company-files-#{@company.uuid}"}
          kind={:files}
          resource_type={:company}
          resource={@company}
          phoenix_kit_current_user={@phoenix_kit_current_user}
        />
      </div>

      <div :if={@tab == "images"} class="flex flex-col gap-3">
        <.tab_intro text={gettext("Pictures kept on this company; one can be set as its logo. Add them here with the Add images button.")} />
        <.live_component
          module={MediaComponent}
          id={"crm-company-images-#{@company.uuid}"}
          kind={:images}
          resource_type={:company}
          resource={@company}
          phoenix_kit_current_user={@phoenix_kit_current_user}
        />
      </div>

      <div :if={@tab == "comments"} class="flex flex-col gap-3">
        <.tab_intro text={
          gettext("Notes about the company as a whole, written here. A note about one product it supplies (a promised discount, say) belongs on that item's Suppliers tab in the catalogue, not here.")
        } />
        <.live_component
          module={PhoenixKitComments.Web.CommentsComponent}
          id={"crm-company-comments-#{@company.uuid}"}
          resource_type="crm_company"
          resource_uuid={@company.uuid}
          current_user={@phoenix_kit_current_user}
        />
      </div>

      <%!-- Header-logo picker (Images folder; no `notify` → result lands in
           this LV's handle_info). --%>
      <.live_component
        :if={@show_avatar_picker}
        module={MediaSelectorModal}
        id={"crm-company-avatar-#{@company.uuid}"}
        show={true}
        mode={:single}
        file_type_filter={:image}
        browse={true}
        selected_uuids={Enum.reject([Attachments.avatar_uuid(@company)], &is_nil/1)}
        scope_folder_id={@avatar_folder_uuid}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />
    </div>
    """
  end

  # Circular company logo (header) — click to set/change (Storage required),
  # hover to remove when set. Image if set, else a building icon.
  attr(:url, :string, default: nil)
  attr(:storage_enabled, :boolean, default: false)

  defp company_logo(assigns) do
    ~H"""
    <div class="relative shrink-0 group">
      <button
        type="button"
        phx-click="edit_avatar"
        disabled={!@storage_enabled}
        class="block w-12 h-12 rounded-full overflow-hidden ring-1 ring-base-300 bg-base-300 disabled:cursor-default"
        aria-label={gettext("Change logo")}
      >
        <img :if={@url} src={@url} alt="" class="w-full h-full object-cover" />
        <span
          :if={!@url}
          class="flex items-center justify-center w-full h-full text-base-content/60"
        >
          <.icon name="hero-building-office-2" class="w-6 h-6" />
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
        phx-disable-with="…"
        data-confirm={gettext("Remove this logo?")}
        class="absolute -top-1 -right-1 btn btn-xs btn-circle btn-error opacity-0 group-hover:opacity-100 transition"
        aria-label={gettext("Remove logo")}
      >
        <.icon name="hero-x-mark" class="w-3 h-3" />
      </button>
    </div>
    """
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

  # Small circular member avatar (real photo if set, else initials).
  attr(:contact, :map, default: nil)

  defp member_avatar(assigns) do
    assigns = assign(assigns, :url, assigns.contact && Attachments.avatar_url(assigns.contact))

    ~H"""
    <img
      :if={@url}
      src={@url}
      alt=""
      class="w-9 h-9 rounded-full object-cover ring-1 ring-base-300 shrink-0"
    />
    <div
      :if={!@url}
      class="w-9 h-9 rounded-full bg-base-300 text-base-content/60 flex items-center justify-center text-sm font-semibold shrink-0"
    >
      {member_initials(@contact)}
    </div>
    """
  end

  defp member_initials(%Contact{} = c) do
    c
    |> Contact.display_name()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp member_initials(_), do: "?"

  defp member_role(m),
    do: [m.role_in_company, m.department] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
end
