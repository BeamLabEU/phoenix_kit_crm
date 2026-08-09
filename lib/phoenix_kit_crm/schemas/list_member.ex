defmodule PhoenixKitCRM.Schemas.ListMember do
  @moduledoc """
  The list ↔ contact join (`PhoenixKitCRM.Lists`), carrying a denormalized
  `email` snapshot taken at add-time and its own `status`/`source`.

  `email` is deliberately **not** in the public changeset's castable fields —
  it is only ever set by the context from the contact's current email
  (`PhoenixKitCRM.Lists.add_contact_to_list/3`), so a list survives a later
  change to the contact's own email and a crafted form payload can't forge a
  membership's email. It may be `nil` (the contact just isn't sendable).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKitCRM.Schemas.{Contact, ContactList}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(subscribed pending removed)
  @sources ~w(manual import form api)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          list_uuid: UUIDv7.t() | nil,
          list: ContactList.t() | Ecto.Association.NotLoaded.t() | nil,
          contact_uuid: UUIDv7.t() | nil,
          contact: Contact.t() | Ecto.Association.NotLoaded.t() | nil,
          email: String.t() | nil,
          status: String.t() | nil,
          subscribed_at: DateTime.t() | nil,
          unsubscribed_at: DateTime.t() | nil,
          source: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_crm_list_members" do
    field(:email, :string)
    field(:status, :string, default: "subscribed")
    field(:subscribed_at, :utc_datetime)
    field(:unsubscribed_at, :utc_datetime)
    field(:source, :string, default: "manual")
    field(:metadata, :map, default: %{})

    belongs_to(:list, ContactList, foreign_key: :list_uuid, references: :uuid)
    belongs_to(:contact, Contact, foreign_key: :contact_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @castable ~w(list_uuid contact_uuid status source subscribed_at unsubscribed_at)a

  @doc "Changeset for creating/updating a membership. `email` is NOT castable — see moduledoc."
  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(member, attrs) do
    member
    |> cast(attrs, @castable)
    |> validate_required([:list_uuid, :contact_uuid])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> assoc_constraint(:list)
    |> assoc_constraint(:contact)
    |> unique_constraint([:list_uuid, :contact_uuid],
      name: :idx_crm_list_members_list_contact,
      message: "already a member of this list"
    )
    |> unique_constraint(:email,
      name: :idx_crm_list_members_list_email,
      message: "email already in this list"
    )
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec sources() :: [String.t()]
  def sources, do: @sources
end
