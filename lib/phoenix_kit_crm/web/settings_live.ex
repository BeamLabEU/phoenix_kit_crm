defmodule PhoenixKitCRM.Web.SettingsLive do
  @moduledoc """
  CRM settings page — the enable/disable toggle, role opt-in, and the party
  roles (the vocabulary of what a company or person can be: reorder, archive,
  delete, and a link to the add / edit form). `?tab=party-roles` opens that tab.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCRM.{Activity, PartyRoles, PartyRoleTypes, Paths, RoleSettings}

  @tabs ~w(general roles party-roles)

  @impl true
  def mount(_params, _session, socket) do
    if PhoenixKitCRM.can_change_settings?(socket.assigns[:phoenix_kit_current_scope]) do
      mount_settings(socket)
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to change the CRM settings."))
       |> push_navigate(to: Paths.index(), replace: true)}
    end
  end

  defp mount_settings(socket) do
    eligible_roles = RoleSettings.list_eligible_roles()
    enabled_role_uuids = enabled_role_uuids()

    {:ok,
     assign(socket,
       page_title: gettext("CRM"),
       page_section: gettext("Settings"),
       page_section_path: Routes.path("/admin/settings"),
       active_tab: "general",
       enabled: PhoenixKitCRM.enabled?(),
       eligible_roles: eligible_roles,
       enabled_role_uuids: enabled_role_uuids,
       role_user_counts: role_user_counts(),
       party_role_types: [],
       party_role_holders: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["tab"] do
        tab when tab in @tabs -> assign(socket, :active_tab, tab)
        _ -> socket
      end

    {:noreply, load_party_roles(socket)}
  end

  # Every write re-checks the sub-key against the live scope: the page being
  # open is not the permission (a revoke reaches a mounted page, and a
  # crafted event needs no button).
  @impl true
  def handle_event("switch_settings_tab" = event, params, socket),
    do: dispatch(event, params, socket)

  def handle_event(event, params, socket) do
    if PhoenixKitCRM.can_change_settings?(socket.assigns[:phoenix_kit_current_scope]) do
      dispatch(event, params, socket)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("You do not have permission to change the CRM settings.")
       )}
    end
  end

  defp dispatch("switch_settings_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  # ── Party roles ─────────────────────────────────────────────────────

  defp dispatch("reorder_party_roles", %{"ordered_ids" => ids} = params, socket)
       when is_list(ids) do
    :ok = PartyRoleTypes.reorder(ids, Activity.actor_opts(socket))

    {:noreply,
     socket
     |> push_event("sortable:flash", %{uuid: params["moved_id"], status: "ok"})
     |> load_party_roles()}
  end

  defp dispatch("archive_party_role", %{"uuid" => uuid}, socket) do
    change_party_role(
      socket,
      uuid,
      &PartyRoleTypes.archive_type/2,
      gettext("Party role archived")
    )
  end

  defp dispatch("restore_party_role", %{"uuid" => uuid}, socket) do
    change_party_role(
      socket,
      uuid,
      &PartyRoleTypes.restore_type/2,
      gettext("Party role restored")
    )
  end

  defp dispatch("delete_party_role", %{"uuid" => uuid}, socket) do
    with %{} = type <- PartyRoleTypes.get_type(uuid),
         {:ok, _} <- PartyRoleTypes.delete_type(type, Activity.actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, gettext("Party role deleted")) |> load_party_roles()}
    else
      {:error, :builtin} ->
        {:noreply, put_flash(socket, :error, gettext("A built-in role cannot be deleted."))}

      {:error, :in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This role is, or once was, held by a company or person — archive it instead.")
         )}

      _ ->
        {:noreply,
         socket |> put_flash(:error, gettext("Party role not found")) |> load_party_roles()}
    end
  end

  defp dispatch("toggle", _params, socket) do
    result =
      if socket.assigns.enabled,
        do: PhoenixKitCRM.disable_system(),
        else: PhoenixKitCRM.enable_system()

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:enabled, PhoenixKitCRM.enabled?())
         |> put_flash(:info, gettext("CRM settings updated"))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update CRM settings"))}
    end
  end

  defp dispatch("toggle_role", %{"role_uuid" => uuid, "value" => v}, socket) do
    enabled? = v == "on" or v == "true"

    case RoleSettings.set_enabled(uuid, enabled?, Activity.actor_opts(socket)) do
      {:ok, _} ->
        # set_enabled/2 re-registers the role tabs in core's dashboard
        # registry, but the sidebar in this page's layout reads the registry
        # only when it renders, and none of its assigns change here — so the
        # new (or removed) subtab would not show until the operator navigated
        # away. The registry broadcasts badge updates only, never
        # (un)registrations, so a remount of this same page is the one lever
        # a module has; the flash survives it.
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role access updated"))
         |> push_navigate(to: Paths.settings())}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update role access"))}
    end
  end

  defp dispatch(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <.nav_tabs
        active_tab={@active_tab}
        on_change="switch_settings_tab"
        variant={:border}
        tabs={[
          %{id: "general", label: gettext("General"), icon: "hero-cog-6-tooth"},
          %{id: "roles", label: gettext("Role Access"), icon: "hero-user-group"},
          %{id: "party-roles", label: gettext("Party roles"), icon: "hero-tag"}
        ]}
      />

      <div class={@active_tab != "general" && "hidden"}>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl">
            <.icon name="hero-cog-6-tooth" class="w-6 h-6" />
            {gettext("General")}
          </h2>
          <p class="text-base-content/70 text-sm">
            {gettext("Module-specific configuration will appear here as the CRM grows.")}
          </p>

          <div class="divider"></div>

          <.checkbox
            name="crm_enabled"
            checked={@enabled}
            label={gettext("Enable CRM")}
            phx-click="toggle"
          >
            <:description>{gettext("Toggles this module on or off. Same setting as the admin Modules page.")}</:description>
          </.checkbox>
        </div>
      </div>
      </div>

      <div class={@active_tab != "roles" && "hidden"}>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-xl">
            <.icon name="hero-user-group" class="w-5 h-5" />
            {gettext("Role Access")}
          </h2>
          <p class="text-base-content/70 text-sm">
            {gettext("Choose which roles can access the CRM module. Owner and Admin always have access.")}
          </p>

          <div class="divider"></div>

          <div class="flex flex-col gap-3">
            <div :if={@eligible_roles == []} class="text-base-content/50 text-sm">
              {gettext("No eligible roles found.")}
            </div>
            <%!-- Enabled roles carry the portal info the overview used to
                 show — how many users hold the role, and the way into its
                 portal view. This page is where portal access lives now. --%>
            <div
              :for={role <- @eligible_roles}
              class="flex items-start justify-between gap-3 flex-wrap"
            >
              <.checkbox
                name={"role_#{role.uuid}_enabled"}
                checked={MapSet.member?(@enabled_role_uuids, role.uuid)}
                label={role.name}
                phx-click="toggle_role"
                phx-value-role_uuid={role.uuid}
                phx-value-value={if MapSet.member?(@enabled_role_uuids, role.uuid), do: "false", else: "true"}
              >
                <:description :if={Map.get(role, :description)}>{role.description}</:description>
              </.checkbox>
              <div
                :if={MapSet.member?(@enabled_role_uuids, role.uuid)}
                class="text-sm text-base-content/60 shrink-0"
              >
                {ngettext("%{count} user", "%{count} users",
                  Map.get(@role_user_counts, role.uuid, 0),
                  count: Map.get(@role_user_counts, role.uuid, 0)
                )}
                &middot;
                <.link navigate={Paths.role(role.uuid)} class="link link-hover">
                  {gettext("Open portal view")}
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>
      </div>

      <div class={@active_tab != "party-roles" && "hidden"}>
        <.party_roles_card types={@party_role_types} holders={@party_role_holders} />
      </div>

    </div>
    """
  end

  attr(:types, :list, required: true)
  attr(:holders, :map, required: true)

  defp party_roles_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <div class="flex items-start justify-between gap-3 flex-wrap">
          <div>
            <h2 class="card-title text-xl">
              <.icon name="hero-tag" class="w-5 h-5" />
              {gettext("Party roles")}
            </h2>
            <p class="text-base-content/70 text-sm mt-1">
              {gettext(
                "What a company or person can be to you — supplier, carrier, installer… Drag to reorder. An archived role stays on whoever holds it but is no longer offered."
              )}
            </p>
          </div>
          <.link navigate={Paths.party_role_new()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add role")}
          </.link>
        </div>

        <div class="divider"></div>

        <.table_default id="party-roles-list" size="sm">
          <.table_default_header>
            <.table_default_row>
              <.drag_handle_header_cell />
              <.table_default_header_cell>{gettext("Role")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Key")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Held by")}
              </.table_default_header_cell>
              <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
              <.table_default_header_cell class="text-right">
                {gettext("Actions")}
              </.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>

          <.sortable_tbody id="party-roles-body" event="reorder_party_roles">
            <.sortable_row :for={type <- @types} item_id={type.uuid} id={"party-role-#{type.key}"}>
              <.drag_handle_cell />
              <.table_default_cell>
                <span class={["badge gap-1", type.badge]}>
                  <.icon name={type.icon} class="w-3 h-3" />
                  {PartyRoleTypes.name(type)}
                </span>
                <span :if={type.builtin} class="badge badge-ghost badge-xs ml-1">
                  {gettext("built-in")}
                </span>
              </.table_default_cell>
              <.table_default_cell class="font-mono text-xs text-base-content/70">
                {type.key}
              </.table_default_cell>
              <.table_default_cell class="text-right">
                {Map.get(@holders, type.key, 0)}
              </.table_default_cell>
              <.table_default_cell>
                <span :if={type.status == "active"} class="badge badge-success badge-sm">
                  {gettext("Active")}
                </span>
                <span :if={type.status == "archived"} class="badge badge-ghost badge-sm">
                  {gettext("Archived")}
                </span>
              </.table_default_cell>
              <.table_default_cell class="text-right whitespace-nowrap">
                <.link navigate={Paths.party_role_edit(type.uuid)} class="btn btn-ghost btn-xs">
                  {gettext("Edit")}
                </.link>
                <button
                  :if={type.status == "active" and not type.builtin}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="archive_party_role"
                  phx-value-uuid={type.uuid}
                >
                  {gettext("Archive")}
                </button>
                <button
                  :if={type.status == "archived"}
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="restore_party_role"
                  phx-value-uuid={type.uuid}
                >
                  {gettext("Restore")}
                </button>
                <button
                  :if={not type.builtin}
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_party_role"
                  phx-value-uuid={type.uuid}
                  data-confirm={gettext("Delete this role? This cannot be undone.")}
                >
                  {gettext("Delete")}
                </button>
              </.table_default_cell>
            </.sortable_row>
          </.sortable_tbody>
        </.table_default>
      </div>
    </div>
    """
  end

  defp change_party_role(socket, uuid, fun, message) do
    with %{} = type <- PartyRoleTypes.get_type(uuid),
         {:ok, _} <- fun.(type, Activity.actor_opts(socket)) do
      {:noreply, socket |> put_flash(:info, message) |> load_party_roles()}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      _ ->
        {:noreply,
         socket |> put_flash(:error, gettext("Party role not found")) |> load_party_roles()}
    end
  end

  # The only way archiving or restoring a role is refused is the built-in guard.
  defp changeset_message(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :status),
      do: gettext("A built-in role cannot be archived."),
      else: gettext("Could not update the party role")
  end

  defp load_party_roles(socket) do
    # Holders: the parties that hold the role now (companies + people), the
    # same numbers the index tabs show.
    holders =
      Map.merge(
        PartyRoles.role_counts("company"),
        PartyRoles.role_counts("contact"),
        fn _key, companies, contacts -> companies + contacts end
      )

    assign(socket, party_role_types: PartyRoleTypes.list_types(), party_role_holders: holders)
  end

  defp enabled_role_uuids do
    RoleSettings.list_enabled()
    |> Enum.map(& &1.uuid)
    |> MapSet.new()
  end

  # Only enabled roles come back, which is all the template links to — a
  # disabled role has no portal view to open.
  defp role_user_counts do
    RoleSettings.list_enabled_with_user_counts()
    |> Map.new(&{&1.uuid, &1.count})
  end
end
