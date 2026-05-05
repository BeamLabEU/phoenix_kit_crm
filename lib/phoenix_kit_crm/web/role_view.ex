defmodule PhoenixKitCRM.Web.RoleView do
  @moduledoc """
  Admin LiveView for a single CRM role page — lists users assigned to the role
  with per-user persisted column configuration. Supports a card/table view
  toggle (provided by `PhoenixKitWeb.Components.Core.TableDefault`).
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitCRM.Web.ColumnManagement

  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.{ColumnConfig, Paths, Web.CellFormat, Web.ColumnModal}

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
             |> assign(:show_column_modal, false)
             |> assign(:temp_selected_columns, nil)}
        end
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if connected?(socket) do
      users = Roles.users_with_role(socket.assigns.role.name)
      selected = ColumnConfig.get_columns(socket.assigns.current_user_uuid, socket.assigns.scope)

      {:noreply,
       socket
       |> assign(:users, users)
       |> assign(:selected_columns, selected)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("navigate_to_user", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Paths.user_view(uuid))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <h1 class="text-2xl font-bold">{@page_title}</h1>
        <span class="text-sm text-base-content/60">
          {ngettext("%{count} user", "%{count} users", length(@users), count: length(@users))}
        </span>
      </div>

      <TableDefault.table_default
        id="crm-role-users-table"
        toggleable
        items={@users}
        card_title={fn u -> card_title_link(u) end}
        card_fields={fn u -> Enum.map(@selected_columns, &card_field(@scope, &1, u)) end}
      >
        <:toolbar_actions>
          <button class="btn btn-outline btn-sm" phx-click="show_column_modal">
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4" /> {gettext("Columns")}
          </button>
        </:toolbar_actions>

        <TableDefault.table_default_header>
          <TableDefault.table_default_row>
            <TableDefault.table_default_header_cell :for={col <- @selected_columns}>
              {column_label(@scope, col)}
            </TableDefault.table_default_header_cell>
          </TableDefault.table_default_row>
        </TableDefault.table_default_header>

        <TableDefault.table_default_body>
          <TableDefault.table_default_row
            :for={user <- @users}
            class="cursor-pointer"
            phx-click="navigate_to_user"
            phx-value-uuid={user.uuid}
          >
            <TableDefault.table_default_cell :for={col <- @selected_columns}>
              {render_cell(@scope, col, user)}
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

  defp column_label(scope, col) do
    case ColumnConfig.get_column_metadata(scope, col) do
      %{label: label} -> label
      _ -> col
    end
  end

  defp card_field(scope, col, user),
    do: %{label: column_label(scope, col), value: render_cell(scope, col, user)}

  defp render_cell(_scope, "email", u), do: u.email
  defp render_cell(_scope, "username", u), do: u.username || "—"
  defp render_cell(_scope, "full_name", u), do: full_name(u)
  defp render_cell(_scope, "status", u), do: crm_status_html(u.is_active)
  defp render_cell(_scope, "registered", u), do: format_date(u.inserted_at)
  defp render_cell(_scope, "last_confirmed", u), do: format_date(u.confirmed_at)
  defp render_cell(_scope, "location", u), do: location(u)

  defp render_cell(scope, "custom_" <> _ = col, u),
    do: CellFormat.render_custom_cell(scope, col, u)

  defp render_cell(_scope, _col, _u), do: "—"

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
