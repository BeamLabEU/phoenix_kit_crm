defmodule PhoenixKitCRM.Web.RoleView do
  @moduledoc """
  Admin LiveView for a single CRM role page — lists users assigned to the role
  with per-user persisted column configuration. Supports a card/table view
  toggle (provided by `PhoenixKitWeb.Components.Core.TableDefault`).
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitCRM.Web.ColumnManagement
  use Gettext, backend: PhoenixKitCRM.Gettext

  # `row_link/1` isn't part of the `:live_view` macro's default import set
  # (confirmed: absent from `phoenix_kit_web.ex`'s `import` list), so each
  # consumer imports it explicitly — the same `only:` form core's own
  # `users.ex`/`activity/index.ex` use, restricted to keep this module's own
  # `render_cell/3` clause dispatch unambiguous.
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.{ColumnConfig, Contacts, Paths, Web.CellFormat, Web.ColumnModal}

  alias PhoenixKitWeb.Components.Core.TableDefault

  @impl true
  def mount(%{"role_uuid" => role_uuid} = _params, _session, socket) do
    cond do
      not PhoenixKitCRM.enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, gettext("CRM is not enabled."))
         |> push_navigate(to: Paths.index(), replace: true)}

      not PhoenixKitCRM.RoleSettings.enabled?(role_uuid) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("This role does not have CRM access."))
         |> push_navigate(to: Paths.index(), replace: true)}

      true ->
        case Roles.get_role_by_uuid(role_uuid) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, gettext("Role not found."))
             |> push_navigate(to: Paths.index(), replace: true)}

          role ->
            scope = {:role, role_uuid}
            current_user = socket.assigns.phoenix_kit_current_user

            {:ok,
             socket
             |> assign(:page_title, gettext("CRM — %{name}", name: role.name))
             |> assign(:role, role)
             |> assign(:scope, scope)
             |> assign(:current_user_uuid, current_user.uuid)
             |> assign(:users, [])
             |> assign(:selected_columns, ColumnConfig.default_columns(scope))
             # No DB query in mount/3 (it runs twice). handle_params/3 loads the
             # real metadata on connect; the empty map keeps the static first
             # paint safe (labels fall back to the column id until connected).
             |> assign(:column_meta, %{})
             |> assign(:crm_contacts, %{})
             |> assign(:show_column_modal, false)
             |> assign(:temp_selected_columns, nil)}
        end
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    if connected?(socket) do
      socket = maybe_reload_role(socket, params["role_uuid"])
      users = Roles.users_with_role(socket.assigns.role.name)
      selected = ColumnConfig.get_columns(socket.assigns.current_user_uuid, socket.assigns.scope)

      {:noreply,
       socket
       |> assign(:users, users)
       |> assign(:selected_columns, selected)
       |> assign(:column_meta, ColumnConfig.column_metadata_map(socket.assigns.scope))
       |> assign(:crm_contacts, load_crm_contacts(selected, users))}
    else
      {:noreply, socket}
    end
  end

  # Ticking the "CRM contact" column on must load the map that column reads,
  # or every cell renders "—" until a reload; the map is loaded only while the
  # column is on screen (see load_crm_contacts/2), and a column save does not
  # re-run handle_params/3.
  defp columns_saved(socket) do
    assign(
      socket,
      :crm_contacts,
      load_crm_contacts(socket.assigns.selected_columns, socket.assigns.users)
    )
  end

  # One query for the whole page instead of one per row. `render/1` runs on
  # every diff (opening the column modal, a card/table toggle), so a per-row
  # lookup in a render helper is a query storm, not just an N+1 on load.
  # Skipped entirely when the column isn't on screen.
  defp load_crm_contacts(selected_columns, users) do
    if "crm_contact" in selected_columns do
      users |> Enum.map(& &1.uuid) |> Contacts.map_by_user_uuids()
    else
      %{}
    end
  end

  # Re-resolve role/scope when the URL points at a different role than the one
  # loaded at mount. Latent today (no inter-role patch links exist), but it
  # removes the stale-scope footgun if such a link is ever added. The common
  # case — same role as mount — returns the socket untouched.
  defp maybe_reload_role(socket, role_uuid) when is_binary(role_uuid) and role_uuid != "" do
    if socket.assigns[:role] && socket.assigns.role.uuid == role_uuid do
      socket
    else
      case Roles.get_role_by_uuid(role_uuid) do
        nil ->
          socket

        role ->
          scope = {:role, role_uuid}

          socket
          |> assign(:role, role)
          |> assign(:scope, scope)
          |> assign(:page_title, gettext("CRM — %{name}", name: role.name))
          |> assign(:selected_columns, ColumnConfig.default_columns(scope))
          |> assign(:column_meta, ColumnConfig.column_metadata_map(scope))
      end
    end
  end

  defp maybe_reload_role(socket, _role_uuid), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <TableDefault.table_default
        id="crm-role-users-table"
        toggleable
        items={@users}
        card_title={fn u -> card_title_link(u) end}
        card_fields={
          fn u -> Enum.map(@selected_columns, &card_field(@column_meta, @crm_contacts, &1, u)) end
        }
      >
        <:toolbar_title>
          <span class="text-sm text-base-content/60">
            {ngettext("%{count} user", "%{count} users", length(@users), count: length(@users))}
          </span>
        </:toolbar_title>
        <:toolbar_actions>
          <button class="btn btn-outline btn-sm" phx-click="show_column_modal">
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4" /> {gettext("Columns")}
          </button>
        </:toolbar_actions>

        <TableDefault.table_default_header>
          <TableDefault.table_default_row>
            <TableDefault.table_default_header_cell :for={col <- @selected_columns}>
              {column_label(@column_meta, col)}
            </TableDefault.table_default_header_cell>
          </TableDefault.table_default_row>
        </TableDefault.table_default_header>

        <TableDefault.table_default_body>
          <TableDefault.table_default_row
            :for={user <- @users}
            class="relative transform-gpu cursor-pointer"
          >
            <%!-- The row-link overlay must stay anchored to the `<tr>`, so no
                 cell may be `relative`: that would make the cell the
                 positioned ancestor and collapse the overlay onto it. The one
                 interactive cell (`crm_contact`) lifts its own link above the
                 overlay instead — see `crm_contact_cell/2`. --%>
            <TableDefault.table_default_cell :for={
              {col, index} <- Enum.with_index(@selected_columns)
            }>
              <.row_link :if={index == 0} navigate={Paths.user_view(user.uuid)} label={user.email} />
              {render_cell(@column_meta, @crm_contacts, col, user)}
            </TableDefault.table_default_cell>
          </TableDefault.table_default_row>

          <TableDefault.table_default_row :if={@users == []}>
            <TableDefault.table_default_cell colspan={length(@selected_columns)}>
              <div class="text-center text-base-content/50 py-8">
                {gettext("No users with this role.")}
              </div>
            </TableDefault.table_default_cell>
          </TableDefault.table_default_row>
        </TableDefault.table_default_body>
      </TableDefault.table_default>

      <ColumnModal.column_modal
        show={@show_column_modal}
        scope={@scope}
        selected={@selected_columns}
        temp_selected={@temp_selected_columns}
      />
    </div>
    """
  end

  defp column_label(column_meta, col) do
    case Map.get(column_meta, col) do
      %{label: label} -> label
      _ -> col
    end
  end

  defp card_field(column_meta, crm_contacts, col, user),
    do: %{
      label: column_label(column_meta, col),
      value: render_cell(column_meta, crm_contacts, col, user)
    }

  defp render_cell(_meta, _contacts, "email", u), do: u.email
  defp render_cell(_meta, _contacts, "username", u), do: u.username || "—"
  defp render_cell(_meta, _contacts, "full_name", u), do: full_name(u)
  defp render_cell(_meta, _contacts, "status", u), do: crm_status_html(u.is_active)
  defp render_cell(_meta, _contacts, "registered", u), do: format_date(u.inserted_at)
  defp render_cell(_meta, _contacts, "last_confirmed", u), do: format_date(u.confirmed_at)
  defp render_cell(_meta, _contacts, "location", u), do: location(u)

  defp render_cell(_meta, contacts, "crm_contact", u),
    do: crm_contact_cell(Map.get(contacts, u.uuid))

  defp render_cell(meta, _contacts, "custom_" <> _ = col, u),
    do: CellFormat.render_custom_cell(meta, col, u)

  defp render_cell(_meta, _contacts, _col, _u), do: "—"

  defp full_name(u) do
    [Map.get(u, :first_name), Map.get(u, :last_name)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> case do
      "" -> "—"
      n -> n
    end
  end

  defp card_title_link(u) do
    assigns = %{href: Paths.user_view(u.uuid), label: u.email}
    ~H|<.link navigate={@href} class="link link-hover font-medium">{@label}</.link>|
  end

  # "CRM contact" column — a link to the contact when this portal user is
  # linked to one, "—" otherwise. The contact comes from the page-wide map
  # loaded in `handle_params/3`, never from a lookup here: this runs once per
  # row on every render. `relative z-10` lifts the link above the row-link
  # overlay (which is `z-0`) so it stays clickable — on the link itself, not
  # the cell, so the overlay keeps spanning the whole row.
  defp crm_contact_cell(nil), do: "—"

  defp crm_contact_cell(contact) do
    assigns = %{href: Paths.contact(contact.uuid)}
    ~H|<.link navigate={@href} class="link link-hover relative z-10">{gettext("View")}</.link>|
  end

  defp crm_status_html(true) do
    assigns = %{}
    ~H|<.status_badge status="active" size={:sm} />|
  end

  defp crm_status_html(_) do
    assigns = %{}
    ~H|<.status_badge status="inactive" size={:sm} />|
  end

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(_), do: "—"

  defp location(u) do
    [Map.get(u, :registration_city), Map.get(u, :registration_country)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
    |> case do
      "" -> "—"
      l -> l
    end
  end
end
