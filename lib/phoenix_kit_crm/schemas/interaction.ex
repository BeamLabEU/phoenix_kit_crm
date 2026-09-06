defmodule PhoenixKitCRM.Schemas.Interaction do
  @moduledoc """
  A logged interaction ("client called, we discussed X") — a structured log
  entry (type + when + body) with N resolvable involved parties, anchored to
  exactly one record: a `Contact` OR (since V05) a `Company`.

  The **anchor** — the exclusive contact/company arc — is which record the
  interaction is *about*; the `subject` column is merely its title, hence the
  different word. "Anna at Acme" is a company-anchored interaction with Anna
  as an involved party. The anchor is immutable after creation
  (`update_changeset/2` never casts it): feeds, activity entries and
  broadcasts all key off it, so moving it would rewrite ownership everywhere.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKitCRM.Gettext
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Schemas.{Company, Contact, InteractionParty}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @types ~w(call email meeting note other)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          contact_uuid: UUIDv7.t() | nil,
          contact: Contact.t() | Ecto.Association.NotLoaded.t() | nil,
          company_uuid: UUIDv7.t() | nil,
          company: Company.t() | Ecto.Association.NotLoaded.t() | nil,
          interaction_type: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          time_zone: String.t() | nil,
          subject: String.t() | nil,
          body: String.t() | nil,
          owner_user_uuid: UUIDv7.t() | nil,
          owner_user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          parties: [InteractionParty.t()] | Ecto.Association.NotLoaded.t(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_crm_interactions" do
    field(:interaction_type, :string, default: "note")
    field(:occurred_at, :utc_datetime)
    # The zone `occurred_at` was typed in — an IANA id or a legacy offset, the
    # value as core keeps it — so the wall clock the person meant can be
    # re-resolved on its own. Nil on rows written before the column existed.
    field(:time_zone, :string)
    field(:subject, :string)
    field(:body, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:contact, Contact, foreign_key: :contact_uuid, references: :uuid)
    belongs_to(:company, Company, foreign_key: :company_uuid, references: :uuid)
    belongs_to(:owner_user, User, foreign_key: :owner_user_uuid, references: :uuid)

    has_many(:parties, InteractionParty,
      foreign_key: :interaction_uuid,
      on_delete: :delete_all,
      preload_order: [asc: :position]
    )

    timestamps(type: :utc_datetime)
  end

  @castable ~w(contact_uuid company_uuid interaction_type occurred_at time_zone subject body owner_user_uuid metadata)a
  @anchor_fields ~w(contact_uuid company_uuid)a

  @doc """
  CREATE-only changeset — the only one that casts the anchor fields. Anchor
  immutability is an application-level rule, not a DB constraint (the CHECK
  only pins exactly-one): reusing this changeset for an UPDATE would let
  attrs retarget the row to another anchor, silently moving it between
  feeds, activity ownership and broadcasts. Updates go through
  `update_changeset/2`.
  """
  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(interaction, attrs) do
    interaction
    |> cast(attrs, @castable)
    |> maybe_default_occurred_at()
    |> validate_required([:interaction_type, :occurred_at])
    |> validate_anchor()
    |> validate_inclusion(:interaction_type, @types,
      message: "must be one of: #{Enum.join(@types, ", ")}"
    )
    |> validate_length(:subject, max: 255)
    |> validate_length(:time_zone, max: 64)
    |> assoc_constraint(:contact)
    |> assoc_constraint(:company)
    |> assoc_constraint(:owner_user)
    |> check_constraint(:contact_uuid,
      name: :phoenix_kit_crm_interactions_anchor_xor,
      message: "must have exactly one anchor — a contact or a company"
    )
  end

  @doc """
  Changeset for edits. Never casts the anchor — see the moduledoc. A caller
  smuggling `contact_uuid`/`company_uuid` into `attrs` is silently ignored,
  which is the point.
  """
  @spec update_changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def update_changeset(interaction, attrs) do
    interaction
    |> cast(attrs, @castable -- @anchor_fields)
    |> maybe_default_occurred_at()
    |> validate_required([:interaction_type, :occurred_at])
    |> validate_inclusion(:interaction_type, @types,
      message: "must be one of: #{Enum.join(@types, ", ")}"
    )
    |> validate_length(:subject, max: 255)
    |> validate_length(:time_zone, max: 64)
    |> assoc_constraint(:owner_user)
  end

  # Exactly one anchor. Both errors land on visible fields so a form shows
  # them; the DB CHECK is the backstop, this is the 422 in front of the 500.
  defp validate_anchor(changeset) do
    contact = get_field(changeset, :contact_uuid)
    company = get_field(changeset, :company_uuid)

    cond do
      is_nil(contact) and is_nil(company) ->
        add_error(changeset, :contact_uuid, "an anchor (contact or company) is required")

      not is_nil(contact) and not is_nil(company) ->
        add_error(
          changeset,
          :company_uuid,
          "an interaction has one anchor — a contact or a company, not both"
        )

      true ->
        changeset
    end
  end

  defp maybe_default_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.truncate(DateTime.utc_now(), :second))
      _ -> changeset
    end
  end

  @spec types() :: [String.t()]
  def types, do: @types

  @spec type_label(String.t()) :: String.t()
  def type_label("call"), do: gettext("Call")
  def type_label("email"), do: gettext("Email")
  def type_label("meeting"), do: gettext("Meeting")
  def type_label("note"), do: gettext("Note")
  def type_label("other"), do: gettext("Other")
  def type_label(other), do: other
end
