defmodule PhoenixKitCRM.Web.CompaniesView do
  @moduledoc """
  LiveView for the CRM Companies subtab — skeleton page (no schema yet).

  Guarded by `PhoenixKitCRM.enabled?()` and the `crm_companies_enabled` setting.
  Renders a placeholder table whose visible columns are persisted per user via
  `PhoenixKitCRM.UserRoleView`.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKitCRM.{Paths, UserRoleView}

  @default_columns ["name", "tax_id", "status"]
  @column_labels %{"name" => "Название", "tax_id" => "ИНН", "status" => "Статус"}

  @impl true
  def mount(_params, _session, socket) do
    unless PhoenixKitCRM.enabled?() do
      {:ok,
       socket
       |> put_flash(:error, "CRM is not enabled.")
       |> push_navigate(to: Paths.index(), replace: true)}
    else
      unless Settings.get_boolean_setting("crm_companies_enabled", false) do
        {:ok,
         socket
         |> put_flash(:error, "Companies section is not enabled.")
         |> push_navigate(to: Paths.index(), replace: true)}
      else
        current_user = socket.assigns.phoenix_kit_current_user
        view_config = UserRoleView.get_view_config(current_user.uuid, :companies)

        visible_columns =
          case Map.get(view_config, "columns") do
            cols when is_list(cols) and cols != [] -> cols
            _ -> @default_columns
          end

        {:ok,
         assign(socket,
           page_title: "CRM — Companies / Юрлица",
           view_config: view_config,
           visible_columns: visible_columns,
           columns_panel_open: false
         )}
      end
    end
  end

  @impl true
  def handle_event("toggle_column", %{"column" => col}, socket) do
    current_user = socket.assigns.phoenix_kit_current_user

    visible_columns =
      if col in socket.assigns.visible_columns do
        List.delete(socket.assigns.visible_columns, col)
      else
        socket.assigns.visible_columns ++ [col]
      end

    updated_config = Map.put(socket.assigns.view_config, "columns", visible_columns)
    UserRoleView.put_view_config(current_user.uuid, :companies, updated_config)

    {:noreply, assign(socket, visible_columns: visible_columns, view_config: updated_config)}
  end

  @impl true
  def handle_event("toggle_columns_panel", _params, socket) do
    {:noreply, assign(socket, columns_panel_open: !socket.assigns.columns_panel_open)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :available_columns, @default_columns)
    assigns = assign(assigns, :column_labels, @column_labels)

    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">
          <.icon name="hero-building-office-2" class="w-6 h-6 inline mr-1" />
          Companies / Юрлица
        </h1>
        <button
          class="btn btn-outline btn-sm"
          phx-click="toggle_columns_panel"
        >
          <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
          Columns
        </button>
      </div>

      <div :if={@columns_panel_open} class="card bg-base-200 shadow">
        <div class="card-body py-4">
          <h3 class="font-semibold text-sm mb-2">Visible columns</h3>
          <div class="flex flex-wrap gap-4">
            <label :for={col <- @available_columns} class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                class="checkbox checkbox-primary checkbox-sm"
                checked={col in @visible_columns}
                phx-click="toggle_column"
                phx-value-column={col}
              />
              <span class="text-sm">{Map.get(@column_labels, col, col)}</span>
            </label>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <div class="alert alert-info mb-4">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span>
              Функциональность в разработке. Схема юрлиц будет добавлена в следующем релизе.
            </span>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-zebra w-full">
              <thead>
                <tr>
                  <th :for={col <- @visible_columns}>{Map.get(@column_labels, col, col)}</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td colspan={length(@visible_columns)} class="text-center text-base-content/50 py-8">
                    Нет данных
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
