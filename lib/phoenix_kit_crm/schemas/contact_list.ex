defmodule PhoenixKitCRM.Schemas.ContactList do
  @moduledoc """
  A named, sluggable CRM contact list (`PhoenixKitCRM.Lists`).

  `subscriber_count` is a maintained cache — never cast from form params, it's
  only ever written by the context alongside the membership mutation that
  changes it. `subscribable` is pre-provisioned for the Stage-4 preference
  center; it has no effect yet.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKitCRM.Schemas.ListMember

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active archived)
  # Same format core's `User.validate_locale_value/1` checks, and the same
  # local copy `PhoenixKitCRM.Schemas.Contact` keeps for its own `locale` —
  # kept local here too so this schema doesn't reach into core internals or
  # a sibling schema for a one-line format check.
  @locale_format ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          status: String.t() | nil,
          subscribable: boolean(),
          subscriber_count: integer(),
          locale: String.t() | nil,
          metadata: map(),
          members: [ListMember.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_crm_lists" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:subscribable, :boolean, default: false)
    field(:subscriber_count, :integer, default: 0)
    field(:locale, :string)
    field(:metadata, :map, default: %{})

    has_many(:members, ListMember, foreign_key: :list_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @castable ~w(name slug description status subscribable locale)a

  @doc "Public changeset for create/edit. `subscriber_count` is NOT castable here."
  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(list, attrs) do
    list
    |> cast(attrs, @castable)
    # Runs before validate_required so a name-only create (no explicit slug)
    # doesn't get flagged as missing slug before it's been filled in.
    |> auto_generate_slug()
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> maybe_validate_locale()
    |> unique_constraint(:slug, name: :idx_crm_lists_slug)
  end

  defp maybe_validate_locale(changeset) do
    case get_field(changeset, :locale) do
      l when is_binary(l) and l != "" ->
        validate_format(changeset, :locale, @locale_format,
          message: "must be a valid locale format (e.g., en, en-US)"
        )

      _ ->
        changeset
    end
  end

  defp auto_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
