defmodule PhoenixKitCRM.UserRoleViewConfig do
  @moduledoc """
  Schema for per-user, per-scope CRM view configuration.

  Stores user preferences (e.g. visible columns) keyed by user UUID and scope.
  Scope is either `"companies"` or `"role:<uuid>"`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          uuid: binary(),
          user_uuid: binary(),
          scope: String.t(),
          view_config: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "phoenix_kit_crm_user_role_view" do
    field(:user_uuid, :binary_id)
    field(:scope, :string)
    field(:view_config, :map, default: %{})
    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user role view config.

  ## Examples

      iex> changeset(%UserRoleViewConfig{}, %{user_uuid: uuid, scope: "companies", view_config: %{}})
      %Ecto.Changeset{valid?: true}
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:user_uuid, :scope, :view_config])
    |> validate_required([:user_uuid, :scope])
    |> unique_constraint([:user_uuid, :scope])
  end
end
