defmodule PhoenixKitCRM.Web.ColumnModal do
  @moduledoc """
  Function component that renders the "Customize columns" modal used by both
  `RoleView` and `CompaniesView`. UX mirrors `PhoenixKit.Users` table column
  picker: drag-to-reorder selected columns on the left, click-to-add available
  columns on the right.

  The host LiveView must implement these `handle_event/3` callbacks (provided
  by `PhoenixKitCRM.Web.ColumnManagement`):

    * `"hide_column_modal"`
    * `"add_column"` (`%{"column_id" => id}`)
    * `"remove_column"` (`%{"column_id" => id}`)
    * `"reorder_selected_columns"` (`%{"ordered_ids" => [...]}`)
    * `"update_table_columns"` (form submit, `%{"column_order" => csv}`)
    * `"reset_to_defaults"`
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitCRM.ColumnConfig
  alias PhoenixKitWeb.Components.Core.DraggableList

  attr(:show, :boolean, required: true)
  attr(:scope, :any, required: true)
  attr(:selected, :list, required: true)
  attr(:temp_selected, :list, default: nil)

  def column_modal(assigns) do
    available = ColumnConfig.available_columns(assigns.scope)
    current = assigns.temp_selected || assigns.selected

    assigns =
      assigns
      |> assign(:available, available)
      |> assign(:current, current)

    ~H"""
    <%= if @show do %>
      <div class="modal modal-open" id="crm-column-modal">
        <div class="modal-box max-w-5xl max-h-[90vh] overflow-hidden">
          <h3 class="font-bold text-xl mb-4">Customize columns</h3>
          <p class="text-base-content/70 mb-6">
            Drag selected columns to reorder, or click an available column to add it.
          </p>

          <form phx-submit="update_table_columns" id="crm-column-form">
            <input type="hidden" name="column_order" value={Enum.join(@current, ",")} />

            <div class="flex flex-col lg:flex-row gap-6 mb-6">
              <div class="flex-1">
                <div class="flex items-center justify-between mb-3">
                  <h4 class="text-sm font-semibold uppercase tracking-wide">Selected</h4>
                  <span class="text-xs text-base-content/60">Drag to reorder</span>
                </div>

                <DraggableList.draggable_list
                  id="crm-selected-columns"
                  items={@current}
                  item_id={fn id -> id end}
                  on_reorder="reorder_selected_columns"
                  layout={:list}
                  gap="space-y-2"
                  class="min-h-[200px] max-h-[400px] overflow-y-auto border-2 border-dashed border-base-300 rounded-lg p-3"
                  item_class="flex items-center p-3 rounded-lg bg-primary/10 border border-primary/30 hover:bg-primary/20"
                >
                  <:item :let={column_id}>
                    <% meta = ColumnConfig.get_column_metadata(@scope, column_id) %>
                    <div class="text-primary/60 mr-3">
                      <.icon name="hero-bars-3" class="h-5 w-5" />
                    </div>
                    <span class="flex-1 font-medium">
                      {(meta && meta.label) || column_id}
                    </span>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs btn-circle text-error/60 hover:text-error"
                      phx-click="remove_column"
                      phx-value-column_id={column_id}
                      title="Remove"
                    >
                      <.icon name="hero-x-mark" class="h-4 w-4" />
                    </button>
                  </:item>
                </DraggableList.draggable_list>

                <%= if @current == [] do %>
                  <div class="text-center py-12 text-base-content/40 border-2 border-dashed rounded-lg mt-2">
                    <.icon name="hero-clipboard-document-list" class="h-12 w-12 mx-auto mb-3" />
                    <p class="text-sm">No columns selected</p>
                  </div>
                <% end %>
              </div>

              <div class="flex-1">
                <div class="flex items-center justify-between mb-3">
                  <h4 class="text-sm font-semibold uppercase tracking-wide">Available</h4>
                  <span class="text-xs text-base-content/60">Click to add</span>
                </div>

                <div class="max-h-[400px] overflow-y-auto border border-base-200 rounded-lg p-3">
                  <%= if map_size(@available.standard) > 0 do %>
                    <h5 class="text-xs font-semibold text-base-content/60 mb-2 uppercase">
                      Standard
                    </h5>
                    <div class="space-y-1 mb-3">
                      <%= for {id, meta} <- @available.standard, id not in @current do %>
                        <button
                          type="button"
                          class="w-full flex items-center p-2 rounded-lg hover:bg-base-200 text-left border border-transparent hover:border-base-300"
                          phx-click="add_column"
                          phx-value-column_id={id}
                        >
                          <span class="flex-1 font-medium text-sm">{meta.label}</span>
                          <.icon name="hero-plus" class="h-4 w-4 text-success/60" />
                        </button>
                      <% end %>
                    </div>
                  <% end %>

                  <%= if map_size(@available.custom) > 0 do %>
                    <h5 class="text-xs font-semibold text-base-content/60 mb-2 uppercase">
                      Custom
                    </h5>
                    <div class="space-y-1">
                      <%= for {id, meta} <- @available.custom, id not in @current do %>
                        <button
                          type="button"
                          class="w-full flex items-center p-2 rounded-lg hover:bg-base-200 text-left border border-transparent hover:border-base-300"
                          phx-click="add_column"
                          phx-value-column_id={id}
                        >
                          <span class="flex-1 font-medium text-sm">{meta.label}</span>
                          <.icon name="hero-plus" class="h-4 w-4 text-success/60" />
                        </button>
                      <% end %>
                    </div>
                  <% end %>

                  <%= if available_count(@available, @current) == 0 do %>
                    <div class="text-center py-8 text-base-content/40">
                      <p class="text-sm">All columns selected</p>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="modal-action">
              <button type="submit" class="btn btn-primary">Apply</button>
              <button type="button" class="btn btn-outline" phx-click="reset_to_defaults">
                Defaults
              </button>
              <button type="button" class="btn btn-ghost" phx-click="hide_column_modal">
                Cancel
              </button>
            </div>
          </form>
        </div>
        <div class="modal-backdrop" phx-click="hide_column_modal"></div>
      </div>
    <% end %>
    """
  end

  defp available_count(available, selected) do
    standard_left = Enum.count(available.standard, fn {id, _} -> id not in selected end)
    custom_left = Enum.count(available.custom, fn {id, _} -> id not in selected end)
    standard_left + custom_left
  end
end
