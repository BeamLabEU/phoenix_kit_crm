defmodule PhoenixKitCRM.Web.RoleView do
  @moduledoc """
  Admin LiveView for a single CRM role page — lists users assigned to the role
  and allows per-user column configuration.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Roles
  alias PhoenixKitCRM.UserRoleView

  @default_columns ["email", "username", "status"]

  @available_columns [
    {"email", "Email"},
    {"username", "Username"},
    {"status", "Status"}
  ]

  @impl true
  def mount(%{"role_uuid" => role_uuid} = _params, _session, socket) do
    unless PhoenixKitCRM.enabled?() do
      {:ok,
       push_navigate(socket, to: "/admin/crm", replace: true)
       |> put_flash(:error, "CRM is not enabled.")}
    else
      unless PhoenixKitCRM.RoleSettings.enabled?(role_uuid) do
        {:ok,
         push_navigate(socket, to: "/admin/crm", replace: true)
         |> put_flash(:error, "This role does not have CRM access.")}
      else
        case Roles.get_role_by_uuid(role_uuid) do
          nil ->
            {:ok,
             push_navigate(socket, to: "/admin/crm", replace: true)
             |> put_flash(:error, "Role not found.")}

          role ->
            current_user = socket.assigns.phoenix_kit_current_user
            users = Roles.users_with_role(role.name)

            view_config = UserRoleView.get_view_config(current_user.uuid, {:role, role_uuid})
            columns = Map.get(view_config, "columns", @default_columns)

            {:ok,
             assign(socket,
               page_title: "CRM — #{role.name}",
               role: role,
               role_uuid: role_uuid,
               users: users,
               view_config: view_config,
               columns: columns,
               available_columns: @available_columns,
               column_panel_open: false
             )}
        end
      end
    end
  end

  @impl true
  def handle_event("toggle_column", %{"column" => col}, socket) do
    current_user = socket.assigns.phoenix_kit_current_user
    columns = socket.assigns.columns

    updated_columns =
      if col in columns do
        List.delete(columns, col)
      else
        columns ++ [col]
      end

    updated_config = Map.put(socket.assigns.view_config, "columns", updated_columns)

    UserRoleView.put_view_config(
      current_user.uuid,
      {:role, socket.assigns.role_uuid},
      updated_config
    )

    {:noreply, assign(socket, columns: updated_columns, view_config: updated_config)}
  end

  def handle_event("toggle_column_panel", _params, socket) do
    {:noreply, assign(socket, column_panel_open: !socket.assigns.column_panel_open)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">{@page_title}</h1>
        <button
          class="btn btn-outline btn-sm"
          phx-click="toggle_column_panel"
        >
          <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
          Налаштування колонок
        </button>
      </div>

      <div :if={@column_panel_open} class="card bg-base-200 shadow">
        <div class="card-body py-4">
          <h3 class="font-semibold mb-2">Налаштування колонок</h3>
          <div class="flex flex-wrap gap-4">
            <label :for={{col_key, col_label} <- @available_columns} class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                checked={col_key in @columns}
                phx-click="toggle_column"
                phx-value-column={col_key}
              />
              <span class="text-sm">{col_label}</span>
            </label>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-xl overflow-x-auto">
        <table class="table table-zebra w-full">
          <thead>
            <tr>
              <th :if={"email" in @columns}>Email</th>
              <th :if={"username" in @columns}>Username</th>
              <th :if={"status" in @columns}>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={user <- @users}>
              <td :if={"email" in @columns}>{user.email}</td>
              <td :if={"username" in @columns}>{user.username}</td>
              <td :if={"status" in @columns}>
                <span class={[
                  "badge badge-sm",
                  if(user.is_active, do: "badge-success", else: "badge-ghost")
                ]}>
                  {if user.is_active, do: "Active", else: "Inactive"}
                </span>
              </td>
            </tr>
            <tr :if={@users == []}>
              <td colspan="10" class="text-center text-base-content/50 py-8">
                No users with this role.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
