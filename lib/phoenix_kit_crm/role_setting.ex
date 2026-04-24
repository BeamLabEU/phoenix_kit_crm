defmodule PhoenixKitCRM.RoleSetting do
  @moduledoc """
  Schema for CRM role settings.

  Tracks whether a given role has CRM access enabled.
  The primary key is the role's own UUID (foreign key to `phoenix_kit_user_roles`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:role_uuid, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          role_uuid: binary(),
          enabled: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "phoenix_kit_crm_role_settings" do
    field(:enabled, :boolean, default: false)
    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for role settings.

  ## Examples

      iex> changeset(%RoleSetting{role_uuid: uuid}, %{enabled: true})
      %Ecto.Changeset{valid?: true}
  """
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:enabled])
    |> validate_required([:enabled])
  end
end
