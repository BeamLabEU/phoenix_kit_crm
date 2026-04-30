defmodule PhoenixKitCRM.Web.ColumnManagement do
  @moduledoc """
  `use` macro that injects column-management `handle_event/3` callbacks into
  a CRM LiveView. The host LV must:

    * assign `:scope` (a `PhoenixKitCRM.UserRoleView.scope()`)
    * assign `:current_user_uuid`
    * assign `:selected_columns` (initial column list)
    * call `assign_column_state/3` from `mount/3` to bootstrap modal state

  The macro handles `show_column_modal`, `hide_column_modal`, `add_column`,
  `remove_column`, `reorder_selected_columns`, `update_table_columns` (with
  and without payload), and `reset_to_defaults`.
  """

  defmacro __using__(_opts) do
    quote do
      import PhoenixKitCRM.Web.ColumnManagement, only: [assign_column_state: 3]

      alias PhoenixKitCRM.ColumnConfig

      @impl true
      def handle_event("show_column_modal", _params, socket) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(:show_column_modal, true)
         |> Phoenix.Component.assign(:temp_selected_columns, socket.assigns.selected_columns)}
      end

      def handle_event("hide_column_modal", _params, socket) do
        {:noreply,
         socket
         |> Phoenix.Component.assign(:show_column_modal, false)
         |> Phoenix.Component.assign(:temp_selected_columns, nil)}
      end

      def handle_event("add_column", %{"column_id" => id}, socket) do
        temp = socket.assigns.temp_selected_columns || socket.assigns.selected_columns

        new_temp =
          if id in temp do
            temp
          else
            temp ++ [id]
          end

        {:noreply, Phoenix.Component.assign(socket, :temp_selected_columns, new_temp)}
      end

      def handle_event("remove_column", %{"column_id" => id}, socket) do
        temp = socket.assigns.temp_selected_columns || socket.assigns.selected_columns

        {:noreply,
         Phoenix.Component.assign(socket, :temp_selected_columns, Enum.reject(temp, &(&1 == id)))}
      end

      def handle_event("reset_to_defaults", _params, socket) do
        defaults = ColumnConfig.default_columns(socket.assigns.scope)
        {:noreply, Phoenix.Component.assign(socket, :temp_selected_columns, defaults)}
      end

      def handle_event("reorder_selected_columns", params, socket) do
        new_order =
          case params do
            %{"ordered_ids" => order} when is_list(order) -> order
            %{"order" => order} when is_list(order) -> order
            %{"column_order" => csv} when is_binary(csv) -> String.split(csv, ",", trim: true)
            _ -> []
          end

        if new_order == [] do
          {:noreply, socket}
        else
          temp = socket.assigns.temp_selected_columns || socket.assigns.selected_columns
          valid = Enum.filter(new_order, &(&1 in temp))
          {:noreply, Phoenix.Component.assign(socket, :temp_selected_columns, valid)}
        end
      end

      def handle_event("update_table_columns", %{"column_order" => csv}, socket) do
        ordered = String.split(csv, ",", trim: true)
        save_columns(socket, ordered)
      end

      def handle_event("update_table_columns", _params, socket) do
        ordered = socket.assigns.temp_selected_columns || socket.assigns.selected_columns
        save_columns(socket, ordered)
      end

      defp save_columns(socket, columns) do
        case ColumnConfig.update_columns(
               socket.assigns.current_user_uuid,
               socket.assigns.scope,
               columns
             ) do
          {:ok, _} ->
            valid = ColumnConfig.validate_columns(socket.assigns.scope, columns)

            {:noreply,
             socket
             |> Phoenix.Component.assign(:selected_columns, valid)
             |> Phoenix.Component.assign(:show_column_modal, false)
             |> Phoenix.Component.assign(:temp_selected_columns, nil)
             |> Phoenix.LiveView.put_flash(:info, "Columns updated")}

          {:error, _} ->
            {:noreply,
             socket
             |> Phoenix.LiveView.put_flash(:error, "Failed to save columns")}
        end
      end
    end
  end

  @doc """
  Bootstraps column-modal-related assigns from `mount/3`. Returns a socket with
  `:scope`, `:current_user_uuid`, `:selected_columns`, `:show_column_modal`,
  `:temp_selected_columns` assigned.
  """
  def assign_column_state(socket, scope, current_user_uuid) do
    selected = PhoenixKitCRM.ColumnConfig.get_columns(current_user_uuid, scope)

    socket
    |> Phoenix.Component.assign(:scope, scope)
    |> Phoenix.Component.assign(:current_user_uuid, current_user_uuid)
    |> Phoenix.Component.assign(:selected_columns, selected)
    |> Phoenix.Component.assign(:show_column_modal, false)
    |> Phoenix.Component.assign(:temp_selected_columns, nil)
  end
end
