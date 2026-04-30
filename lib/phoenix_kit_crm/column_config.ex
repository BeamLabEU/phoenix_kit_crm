defmodule PhoenixKitCRM.ColumnConfig do
  @moduledoc """
  Per-scope column configuration for CRM tables and card views.

  Mirrors `PhoenixKit.Users.TableColumns` but is keyed by `(user_uuid, scope)`
  so each admin can have their own column layout per role page and for the
  Companies page. Persistence goes through `PhoenixKitCRM.UserRoleView`.

  ## Scopes

    * `{:role, role_uuid}` — users-of-role page; columns mirror the standard
      PhoenixKit user fields.
    * `:companies` — Companies page; placeholder columns until the legal-entity
      schema lands.
  """

  alias PhoenixKitCRM.UserRoleView

  @role_standard %{
    "email" => %{label: "Email", required: false, type: :email},
    "username" => %{label: "Username", required: false, type: :string},
    "full_name" => %{label: "Full Name", required: false, type: :string},
    "status" => %{label: "Status", required: false, type: :status},
    "registered" => %{label: "Registered", required: false, type: :datetime},
    "last_confirmed" => %{label: "Last Confirmed", required: false, type: :datetime},
    "location" => %{label: "Location", required: false, type: :location}
  }

  @companies_standard %{
    "name" => %{label: "Название", required: false, type: :string},
    "tax_id" => %{label: "ИНН / Tax ID", required: false, type: :string},
    "status" => %{label: "Статус", required: false, type: :status},
    "country" => %{label: "Страна", required: false, type: :string},
    "contact_email" => %{label: "Email", required: false, type: :email},
    "created_at" => %{label: "Создано", required: false, type: :datetime}
  }

  @role_default ["email", "username", "full_name", "status", "registered"]
  @companies_default ["name", "tax_id", "status", "country"]

  @doc "Available columns for a scope, split into `:standard` and `:custom`."
  @spec available_columns(UserRoleView.scope()) :: %{standard: map(), custom: map()}
  def available_columns({:role, _}), do: %{standard: @role_standard, custom: %{}}
  def available_columns(:companies), do: %{standard: @companies_standard, custom: %{}}

  @doc "Default selected column ids for a scope."
  @spec default_columns(UserRoleView.scope()) :: [String.t()]
  def default_columns({:role, _}), do: @role_default
  def default_columns(:companies), do: @companies_default

  @doc "All available column ids for validation."
  @spec all_column_ids(UserRoleView.scope()) :: [String.t()]
  def all_column_ids(scope) do
    %{standard: standard, custom: custom} = available_columns(scope)
    Map.keys(standard) ++ Map.keys(custom)
  end

  @doc "Returns the selected column ids for a user+scope, falling back to defaults."
  @spec get_columns(binary(), UserRoleView.scope()) :: [String.t()]
  def get_columns(user_uuid, scope) when is_binary(user_uuid) do
    config = UserRoleView.get_view_config(user_uuid, scope)

    case Map.get(config, "columns") do
      cols when is_list(cols) and cols != [] -> validate_columns(scope, cols)
      _ -> default_columns(scope)
    end
  end

  @doc "Persists the selected column ids for a user+scope. Empty list resets to defaults."
  @spec update_columns(binary(), UserRoleView.scope(), [String.t()]) ::
          {:ok, UserRoleView.UserRoleViewConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_columns(user_uuid, scope, columns) when is_binary(user_uuid) and is_list(columns) do
    valid = validate_columns(scope, columns)
    current = UserRoleView.get_view_config(user_uuid, scope)
    new_config = Map.put(current, "columns", valid)
    UserRoleView.put_view_config(user_uuid, scope, new_config)
  end

  @doc "Returns metadata for a single column id, or nil."
  @spec get_column_metadata(UserRoleView.scope(), String.t()) :: map() | nil
  def get_column_metadata(scope, column_id) do
    %{standard: standard, custom: custom} = available_columns(scope)
    Map.get(standard, column_id) || Map.get(custom, column_id)
  end

  @doc "Filter input list to only valid column ids for the scope, preserving order."
  @spec validate_columns(UserRoleView.scope(), [String.t()]) :: [String.t()]
  def validate_columns(scope, columns) when is_list(columns) do
    available = MapSet.new(all_column_ids(scope))
    Enum.filter(columns, &MapSet.member?(available, &1))
  end
end
