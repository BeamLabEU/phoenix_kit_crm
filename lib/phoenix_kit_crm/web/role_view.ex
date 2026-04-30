defmodule PhoenixKitCRM.Web.RoleView do
  @moduledoc """
  Admin LiveView for a single CRM role page — lists users assigned to the role
  with per-user persisted column configuration. Supports a card/table view
  toggle (provided by `PhoenixKitWeb.Components.Core.TableDefault`).
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitCRM.Web.ColumnManagement

  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.{ColumnConfig, Web.ColumnModal}

  alias PhoenixKitWeb.Components.Core.TableDefault

  @impl true
  def mount(%{"role_uuid" => role_uuid} = _params, _session, socket) do
    cond do
      not PhoenixKitCRM.enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, "CRM is not enabled.")
         |> push_navigate(to: "/admin/crm", replace: true)}

      not PhoenixKitCRM.RoleSettings.enabled?(role_uuid) ->
        {:ok,
         socket
         |> put_flash(:error, "This role does not have CRM access.")
         |> push_navigate(to: "/admin/crm", replace: true)}

      true ->
        case Roles.get_role_by_uuid(role_uuid) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "Role not found.")
             |> push_navigate(to: "/admin/crm", replace: true)}

          role ->
            current_user = socket.assigns.phoenix_kit_current_user
            users = Roles.users_with_role(role.name)
            scope = {:role, role_uuid}

            socket =
              socket
              |> assign(:page_title, "CRM — #{role.name}")
              |> assign(:role, role)
              |> assign(:users, users)
              |> PhoenixKitCRM.Web.ColumnManagement.assign_column_state(scope, current_user.uuid)

            {:ok, socket}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <h1 class="text-2xl font-bold">{@page_title}</h1>
        <span class="text-sm text-base-content/60">
          {length(@users)} {if length(@users) == 1, do: "user", else: "users"}
        </span>
      </div>

      <TableDefault.table_default
        id="crm-role-users-table"
        toggleable
        items={@users}
        card_title={fn u -> u.email end}
        card_fields={fn u -> Enum.map(@selected_columns, &card_field(&1, u)) end}
      >
        <:toolbar_actions>
          <button class="btn btn-outline btn-sm" phx-click="show_column_modal">
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4" /> Columns
          </button>
        </:toolbar_actions>

        <TableDefault.table_default_header>
          <TableDefault.table_default_row>
            <TableDefault.table_default_header_cell :for={col <- @selected_columns}>
              {column_label(col)}
            </TableDefault.table_default_header_cell>
          </TableDefault.table_default_row>
        </TableDefault.table_default_header>

        <TableDefault.table_default_body>
          <TableDefault.table_default_row :for={user <- @users}>
            <TableDefault.table_default_cell :for={col <- @selected_columns}>
              {render_cell(col, user)}
            </TableDefault.table_default_cell>
          </TableDefault.table_default_row>

          <TableDefault.table_default_row :if={@users == []}>
            <TableDefault.table_default_cell colspan={length(@selected_columns)}>
              <div class="text-center text-base-content/50 py-8">
                No users with this role.
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

  defp column_label(col) do
    case ColumnConfig.get_column_metadata({:role, nil}, col) do
      %{label: label} -> label
      _ -> col
    end
  end

  defp card_field(col, user), do: %{label: column_label(col), value: render_cell(col, user)}

  defp render_cell("email", u), do: u.email
  defp render_cell("username", u), do: u.username || "—"
  defp render_cell("full_name", u), do: full_name(u)
  defp render_cell("status", u), do: crm_status_html(u.is_active)
  defp render_cell("registered", u), do: format_date(u.inserted_at)
  defp render_cell("last_confirmed", u), do: format_date(u.confirmed_at)
  defp render_cell("location", u), do: location(u)
  defp render_cell(_, _), do: "—"

  defp full_name(u) do
    [Map.get(u, :first_name), Map.get(u, :last_name)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> case do
      "" -> "—"
      n -> n
    end
  end

  defp crm_status_html(true),
    do: Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-success">Active</span>))

  defp crm_status_html(_),
    do: Phoenix.HTML.raw(~s(<span class="badge badge-sm badge-ghost">Inactive</span>))

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
