defmodule PhoenixKitCRM.Web.ColumnManagement do
  @moduledoc """
  `use` macro that injects the column picker's `handle_event/3` callbacks
  into a CRM LiveView, on core's live modal (`column_settings_modal/1`,
  every change applied and saved at once) and core's per-user column
  store (`PhoenixKitWeb.TableColumns`). The host LV must:

    * assign `:scope` (a `PhoenixKitCRM.ColumnConfig.scope()`)
    * call `assign_column_state/3` once the scope is known, which assigns
      `:column_spec`, `:selected_columns` and `:show_column_modal`

  The macro handles `show_column_modal`, `hide_column_modal`, `add_column`,
  `remove_column`, `reorder_columns` and `reset_columns`. A host whose rows
  need data loaded only for some columns overrides `columns_saved/1`.
  """

  defmacro __using__(_opts) do
    quote do
      import PhoenixKitCRM.Web.ColumnManagement, only: [assign_column_state: 3]

      @impl true
      def handle_event("show_column_modal", _params, socket),
        do: {:noreply, Phoenix.Component.assign(socket, :show_column_modal, true)}

      def handle_event("hide_column_modal", _params, socket),
        do: {:noreply, Phoenix.Component.assign(socket, :show_column_modal, false)}

      def handle_event(event, params, socket)
          when event in ~w(add_column remove_column reorder_columns reset_columns) do
        spec =
          socket.assigns[:column_spec] || PhoenixKitCRM.ColumnConfig.spec(socket.assigns.scope)

        socket =
          PhoenixKitWeb.TableColumns.handle_event(event, params, socket, spec, :selected_columns)

        {:noreply, columns_saved(socket)}
      end

      # Runs after the column set changed, with `:selected_columns` already
      # updated. A host whose rows need data that is only loaded for SOME
      # columns (RoleView's CRM-contact map is loaded only while that column
      # is on screen) overrides this to re-derive it — `handle_params/3`
      # does not re-run on a column change, so nothing else would.
      defp columns_saved(socket), do: socket
      defoverridable columns_saved: 1
    end
  end

  @doc """
  Assigns the column picker's state for `scope`: `:column_spec`,
  `:selected_columns` (the admin's own choice, else the defaults) and a
  closed `:show_column_modal`. Reads the custom-field catalog once, so
  call it from `handle_params/3` on connect rather than from `mount/3`.
  """
  @spec assign_column_state(
          Phoenix.LiveView.Socket.t(),
          PhoenixKitCRM.ColumnConfig.scope(),
          String.t() | nil
        ) ::
          Phoenix.LiveView.Socket.t()
  def assign_column_state(socket, scope, current_user_uuid) do
    spec = PhoenixKitCRM.ColumnConfig.spec(scope)

    socket
    |> Phoenix.Component.assign(:scope, scope)
    |> Phoenix.Component.assign(:column_spec, spec)
    |> Phoenix.Component.assign(
      :selected_columns,
      PhoenixKitWeb.TableColumns.load(current_user_uuid, spec)
    )
    |> Phoenix.Component.assign(:show_column_modal, false)
  end
end
