defmodule PhoenixKitCRM.Schemas.Company do
  @moduledoc """
  A CRM company / organization record. A first-class record (its own data),
  NOT a login user. Contacts link to it via `CompanyMembership`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Schemas.CompanyMembership

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive)
  @soft_delete_status "trashed"

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          status: String.t() | nil,
          website: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          address: String.t() | nil,
          industry: String.t() | nil,
          notes: String.t() | nil,
          user_uuid: UUIDv7.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          company_memberships: [CompanyMembership.t()] | Ecto.Association.NotLoaded.t(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_crm_companies" do
    field(:name, :string)
    field(:status, :string, default: "active")
    field(:description, :string)
    field(:website, :string)
    field(:email, :string)
    field(:phone, :string)
    field(:address, :string)
    field(:industry, :string)
    field(:notes, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:user, User, foreign_key: :user_uuid, references: :uuid)

    has_many(:company_memberships, CompanyMembership,
      foreign_key: :company_uuid,
      on_delete: :delete_all
    )

    timestamps(type: :utc_datetime)
  end

  @castable ~w(name status description website email phone address industry notes metadata)a

  @doc """
  Public changeset for create/edit. `user_uuid` is NOT castable here — the
  organization-user mirror link is set only via `link_user_changeset/2`, so
  a crafted form payload can't link an arbitrary user.
  """
  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(company, attrs) do
    company
    |> cast(attrs, @castable)
    |> validate_required([:name])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, max: 255)
    |> validate_length(:website, max: 255)
    |> validate_length(:email, max: 255)
    |> validate_length(:phone, max: 50)
    |> validate_length(:industry, max: 255)
  end

  @doc "Sets or clears the optional organization-user mirror link (controlled, not from form params)."
  @spec link_user_changeset(t() | Ecto.Changeset.t(t()), UUIDv7.t() | nil) ::
          Ecto.Changeset.t(t())
  def link_user_changeset(company, user_uuid) do
    company
    |> change(user_uuid: user_uuid)
    |> unique_constraint(:user_uuid,
      name: :idx_crm_companies_user_uuid,
      message: "already linked to a company"
    )
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec soft_delete_status() :: String.t()
  def soft_delete_status, do: @soft_delete_status

  @spec trashed?(t()) :: boolean()
  def trashed?(%__MODULE__{status: @soft_delete_status}), do: true
  def trashed?(%__MODULE__{}), do: false

  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{}), do: "Unnamed"
end
