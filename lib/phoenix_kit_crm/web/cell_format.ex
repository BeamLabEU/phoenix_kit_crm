defmodule PhoenixKitCRM.Web.CellFormat do
  @moduledoc """
  Shared formatters for CRM table/card cells.

  Currently covers user-defined custom field values (`format_custom_value/2`)
  and the `custom_*` cell renderer used by `RoleView` and `OrganizationsView`.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitCRM.ColumnConfig

  @doc """
  Renders a `"custom_<key>"` column for the given user. Looks up metadata in
  the scope's column config; returns `"—"` if the column is unknown or the
  value is missing.
  """
  @spec render_custom_cell(any(), String.t(), map()) :: String.t()
  def render_custom_cell(scope, "custom_" <> _ = column_id, user) do
    case ColumnConfig.get_column_metadata(scope, column_id) do
      %{type: :custom_field, field_key: key, field_type: type} ->
        format_custom_value(Map.get(user.custom_fields || %{}, key), type)

      _ ->
        "—"
    end
  end

  @doc "Formats a custom field value according to its declared type."
  @spec format_custom_value(any(), String.t() | nil) :: String.t()
  def format_custom_value(nil, _), do: "—"
  def format_custom_value("", _), do: "—"
  def format_custom_value(true, "boolean"), do: gettext("Yes")
  def format_custom_value(false, "boolean"), do: gettext("No")
  def format_custom_value("true", "boolean"), do: gettext("Yes")
  def format_custom_value("false", "boolean"), do: gettext("No")
  def format_custom_value(true, "checkbox"), do: gettext("Yes")
  def format_custom_value(false, "checkbox"), do: gettext("No")
  def format_custom_value(list, "checkbox") when is_list(list), do: Enum.join(list, ", ")
  def format_custom_value(%Date{} = d, _), do: Date.to_string(d)
  def format_custom_value(%DateTime{} = dt, _), do: DateTime.to_string(dt)
  def format_custom_value(%NaiveDateTime{} = dt, _), do: NaiveDateTime.to_string(dt)
  def format_custom_value(value, _) when is_binary(value), do: value
  def format_custom_value(value, _), do: to_string(value)
end
