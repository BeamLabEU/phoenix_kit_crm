defmodule PhoenixKitCRM.ColumnConfig do
  @moduledoc """
  Per-scope column configuration for CRM tables and card views.

  Mirrors `PhoenixKit.Users.TableColumns` but is keyed by `(user_uuid, scope)`
  so each admin can have their own column layout per role page and for the
  Organizations page. Persistence goes through `PhoenixKitCRM.UserRoleView`.

  ## Scopes

    * `{:role, role_uuid}` — users-of-role page; columns mirror the standard
      PhoenixKit user fields.
    * `:organizations` — Organizations page; users with `account_type =
      "organization"`.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Users.CustomFields
  alias PhoenixKitCRM.{UserRoleView, UserRoleViewConfig}

  @role_standard [
    {"email", %{label: "Email", required: false, type: :email}},
    {"username", %{label: "Username", required: false, type: :string}},
    {"full_name", %{label: "Full Name", required: false, type: :string}},
    {"status", %{label: "Status", required: false, type: :status}},
    {"registered", %{label: "Registered", required: false, type: :datetime}},
    {"last_confirmed", %{label: "Last Confirmed", required: false, type: :datetime}},
    {"location", %{label: "Location", required: false, type: :location}}
  ]

  @organizations_standard [
    {"organization_name", %{label: "Organization", required: false, type: :string}},
    {"email", %{label: "Email", required: false, type: :email}},
    {"full_name", %{label: "Contact", required: false, type: :string}},
    {"username", %{label: "Username", required: false, type: :string}},
    {"status", %{label: "Status", required: false, type: :status}},
    {"registered", %{label: "Registered", required: false, type: :datetime}},
    {"location", %{label: "Location", required: false, type: :location}}
  ]

  @role_default ["email", "username", "full_name", "status", "registered"]
  @organizations_default ["organization_name", "email", "full_name", "status", "registered"]

  @doc """
  Available columns for a scope, split into `:standard` and `:custom`.

  Each value is an **ordered** list of `{column_id, metadata}` tuples — standard
  columns follow the order declared in this module, custom columns follow the
  `position` ordering from `PhoenixKit.Users.CustomFields`.
  """
  @spec available_columns(UserRoleView.scope()) ::
          %{standard: [{String.t(), map()}], custom: [{String.t(), map()}]}
  def available_columns({:role, _}),
    do: %{standard: translate_labels(@role_standard), custom: custom_field_columns()}

  def available_columns(:organizations),
    do: %{standard: translate_labels(@organizations_standard), custom: custom_field_columns()}

  defp custom_field_columns do
    case Code.ensure_loaded(CustomFields) do
      {:module, _} ->
        load_custom_fields()
        |> Enum.map(fn field ->
          key = field["key"]

          {"custom_" <> key,
           %{
             label: field["label"] || key,
             field_key: key,
             field_type: field["type"],
             required: false,
             type: :custom_field
           }}
        end)

      _ ->
        []
    end
  end

  defp load_custom_fields do
    CustomFields.list_enabled_field_definitions()
  rescue
    UndefinedFunctionError ->
      []

    error ->
      Logger.warning(
        "PhoenixKitCRM: failed to load custom field definitions: #{Exception.message(error)}"
      )

      []
  end

  defp translate_labels(list) do
    Enum.map(list, fn {k, v} ->
      {k, Map.update!(v, :label, &Gettext.gettext(PhoenixKitWeb.Gettext, &1))}
    end)
  end

  @doc "Default selected column ids for a scope."
  @spec default_columns(UserRoleView.scope()) :: [String.t()]
  def default_columns({:role, _}), do: @role_default
  def default_columns(:organizations), do: @organizations_default

  @doc "All available column ids for validation."
  @spec all_column_ids(UserRoleView.scope()) :: [String.t()]
  def all_column_ids(scope) do
    %{standard: standard, custom: custom} = available_columns(scope)
    Enum.map(standard, &elem(&1, 0)) ++ Enum.map(custom, &elem(&1, 0))
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
          {:ok, UserRoleViewConfig.t()} | {:error, Ecto.Changeset.t()}
  def update_columns(user_uuid, scope, columns) when is_binary(user_uuid) and is_list(columns) do
    valid = validate_columns(scope, columns)
    current = UserRoleView.get_view_config(user_uuid, scope)
    new_config = Map.put(current, "columns", valid)
    UserRoleView.put_view_config(user_uuid, scope, new_config)
  end

  @doc "Returns metadata for a single column id, or nil. The `:label` field is translated via gettext."
  @spec get_column_metadata(UserRoleView.scope(), String.t()) :: map() | nil
  def get_column_metadata(scope, column_id) do
    %{standard: standard, custom: custom} = available_columns(scope)

    find_in(standard, column_id) || find_in(custom, column_id)
  end

  defp find_in(list, column_id) do
    case List.keyfind(list, column_id, 0) do
      {_, meta} -> meta
      nil -> nil
    end
  end

  @doc "Filter input list to only valid column ids for the scope, preserving order."
  @spec validate_columns(UserRoleView.scope(), [String.t()]) :: [String.t()]
  def validate_columns(scope, columns) when is_list(columns) do
    available = MapSet.new(all_column_ids(scope))
    Enum.filter(columns, &MapSet.member?(available, &1))
  end
end
