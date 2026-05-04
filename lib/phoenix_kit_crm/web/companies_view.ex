defmodule PhoenixKitCRM.Web.CompaniesView do
  @moduledoc """
  LiveView for the CRM Companies subtab — placeholder data until the
  legal-entity schema lands. Per-user column configuration with card/table
  view toggle.
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitCRM.Web.ColumnManagement

  alias PhoenixKit.Settings
  alias PhoenixKitCRM.{ColumnConfig, Paths, Web.ColumnModal}

  alias PhoenixKitWeb.Components.Core.TableDefault

  @impl true
  def mount(_params, _session, socket) do
    cond do
      not PhoenixKitCRM.enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, gettext("CRM is not enabled."))
         |> push_navigate(to: Paths.index(), replace: true)}

      not Settings.get_boolean_setting("crm_companies_enabled", false) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Companies section is not enabled."))
         |> push_navigate(to: Paths.index(), replace: true)}

      true ->
        current_user = socket.assigns.phoenix_kit_current_user

        {:ok,
         socket
         |> assign(:page_title, gettext("CRM — Companies / Юрлица"))
         |> assign(:companies, [])
         |> assign(:scope, :companies)
         |> assign(:current_user_uuid, current_user.uuid)
         |> assign(:selected_columns, ColumnConfig.default_columns(:companies))
         |> assign(:show_column_modal, false)
         |> assign(:temp_selected_columns, nil)}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if connected?(socket) do
      selected = ColumnConfig.get_columns(socket.assigns.current_user_uuid, :companies)
      {:noreply, assign(socket, :selected_columns, selected)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-6xl px-4 py-6 gap-6">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <h1 class="text-2xl font-bold flex items-center gap-2">
          <.icon name="hero-building-office-2" class="w-6 h-6" /> Companies / Юрлица
        </h1>
      </div>

      <div class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span>
          Функциональность в разработке. Схема юрлиц будет добавлена в следующем релизе.
        </span>
      </div>

      <TableDefault.table_default
        id="crm-companies-table"
        toggleable
        items={@companies}
        card_title={fn c -> Map.get(c, :name, "—") end}
        card_fields={fn c -> Enum.map(@selected_columns, &card_field(@scope, &1, c)) end}
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
          <TableDefault.table_default_row :for={company <- @companies}>
            <TableDefault.table_default_cell :for={col <- @selected_columns}>
              {render_cell(col, company)}
            </TableDefault.table_default_cell>
          </TableDefault.table_default_row>

          <TableDefault.table_default_row :if={@companies == []}>
            <TableDefault.table_default_cell colspan={length(@selected_columns)}>
              <div class="text-center text-base-content/50 py-8">
                {gettext("No companies yet.")}
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

  defp card_field(scope, col, company),
    do: %{label: column_label(scope, col), value: render_cell(col, company)}

  defp render_cell("name", c), do: Map.get(c, :name, "—")
  defp render_cell("tax_id", c), do: Map.get(c, :tax_id, "—")
  defp render_cell("status", c), do: Map.get(c, :status, "—")
  defp render_cell("country", c), do: Map.get(c, :country, "—")
  defp render_cell("contact_email", c), do: Map.get(c, :contact_email, "—")
  defp render_cell("created_at", c), do: Map.get(c, :created_at, "—")
  defp render_cell(_, _), do: "—"
end
