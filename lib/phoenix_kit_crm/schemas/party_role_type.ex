defmodule PhoenixKitCRM.Schemas.PartyRoleType do
  @moduledoc """
  One entry of the party-role vocabulary: what a company or contact can *be*
  to the business ("supplier", "carrier", …). `phoenix_kit_crm_party_roles.role`
  stores a type's `key` and a FK (`ON DELETE/UPDATE RESTRICT`) keeps the two
  honest.

    * `key` — the stable machine value (`carrier`). Lowercase letters, digits
      and `_`, starting with a letter, at most 30 characters. Never
      translated and **immutable after creation**: `changeset/2` does not cast
      it, and the FK refuses an update under existing assignments anyway.
    * `data` — core's multilang JSONB (`PhoenixKit.Utils.Multilang`): the
      translated `"name"` and optional `"description"`. A built-in role is
      seeded with an empty `data` so its name is the gettext string (and keeps
      the existing translations) until an admin overrides it.
    * `badge` / `icon` — a daisyUI badge modifier and a heroicon name, each
      picked from a short list (`badges/0`, `icons/0`) so the Tailwind scan
      finds every class and a forged value cannot reach the markup.
    * `status` — `active` | `archived`. An archived type keeps its
      assignments, badges and lookups but is no longer offered for new grants.
      A built-in cannot be archived: the catalogue grants `supplier` and
      `manufacturer` by key.
    * `builtin` — the four seeded roles; they can be relabelled and
      translated, never deleted.
    * `position` — display order, ascending.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Utils.Multilang

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @statuses ~w(active archived)
  @key_format ~r/\A[a-z][a-z0-9_]*\z/
  @key_max 30

  # Index-page filter ids a role key must not shadow (`?filter=trashed`).
  @reserved_keys ~w(all active inactive trashed)

  @badges ~w(badge-ghost badge-neutral badge-primary badge-secondary badge-accent
             badge-info badge-success badge-warning badge-error)

  @default_badge "badge-ghost"

  @icons ~w(hero-tag hero-truck hero-wrench-screwdriver hero-user-group hero-puzzle-piece
            hero-briefcase hero-building-storefront hero-globe-alt hero-shopping-cart
            hero-cube hero-banknotes hero-star hero-paper-airplane hero-key hero-bolt
            hero-sparkles)

  @default_icon "hero-tag"

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          key: String.t() | nil,
          badge: String.t(),
          icon: String.t(),
          data: map(),
          status: String.t(),
          builtin: boolean(),
          position: integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_crm_party_role_types" do
    field(:key, :string)
    field(:badge, :string, default: @default_badge)
    field(:icon, :string, default: @default_icon)
    field(:data, :map, default: %{})
    field(:status, :string, default: "active")
    field(:builtin, :boolean, default: false)
    field(:position, :integer, default: 0)

    # The primary-language name / description, for the form's primary tab
    # (the translations themselves live in `data`). Never persisted: `sync_data/1`
    # folds a change into `data`, and `PartyRoleTypes.hydrate/1` fills them
    # from it.
    field(:name, :string, virtual: true)
    field(:description, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  @editable ~w(badge icon data status position)a
  @virtual ~w(name description)a

  @doc """
  Creates a custom type. `key` is cast here and nowhere else; `builtin` is
  never castable (only the migration seeds built-ins).
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t(t())
  def create_changeset(%__MODULE__{} = type, attrs) do
    type
    |> cast(attrs, [:key | @editable] ++ @virtual)
    |> validate_data_shape()
    |> sync_data()
    |> derive_key()
    |> validate_required([:key])
    |> validate_key()
    |> validate_editable()
    |> validate_primary_name()
    |> unique_constraint(:key,
      name: :phoenix_kit_crm_party_role_types_key_uniq,
      message: "is already taken"
    )
  end

  @doc "Changeset for edits. The key is not castable; a built-in cannot be archived."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t(t())
  def update_changeset(%__MODULE__{} = type, attrs) do
    type
    |> cast(attrs, @editable ++ @virtual)
    |> validate_data_shape()
    |> sync_data()
    |> validate_editable()
    |> validate_builtin_stays_active()
    |> validate_primary_name()
  end

  # The form edits the primary-language name as a plain field (and, with
  # translations on, ships the merged `data` alongside it). When only the plain
  # fields arrive -- a site with one language, or a caller that has no
  # translations -- they are folded into `data` under the primary language.
  # When `data` is supplied it is the truth: the form already merged it.
  defp sync_data(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp sync_data(changeset) do
    if Map.has_key?(changeset.params, "data") do
      changeset
    else
      # An explicit clear casts to nil, which is already the default for a
      # reloaded virtual field. Params still record that the field was sent.
      fields =
        for {field, key} <- [name: "_name", description: "_description"],
            Map.has_key?(changeset.params, Atom.to_string(field)),
            into: %{},
            do: {key, get_field(changeset, field) || ""}

      if fields == %{} do
        changeset
      else
        existing_data = get_field(changeset, :data) || %{}
        primary = existing_data["_primary_language"] || Multilang.primary_language()
        primary_data = Multilang.get_primary_data(existing_data)

        data =
          Multilang.put_language_data(
            existing_data,
            primary,
            Map.merge(primary_data, fields)
          )

        put_change(changeset, :data, data)
      end
    end
  end

  # The key is derived from the primary-language name unless one was given.
  defp derive_key(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp derive_key(changeset) do
    case get_field(changeset, :key) do
      key when key in [nil, ""] ->
        name = PhoenixKitCRM.PartyRoleTypes.name_from_data(get_field(changeset, :data))

        case PhoenixKitCRM.PartyRoleTypes.derive_key(name) do
          "" -> changeset
          derived -> put_change(changeset, :key, derived)
        end

      _ ->
        changeset
    end
  end

  defp validate_key(changeset) do
    changeset
    |> validate_length(:key, min: 1, max: @key_max)
    |> validate_format(:key, @key_format,
      message: "must be lowercase letters, digits and _, starting with a letter"
    )
    |> validate_exclusion(:key, @reserved_keys, message: "is reserved")
  end

  defp validate_editable(changeset) do
    changeset
    |> validate_required(@editable)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:badge, @badges)
    |> validate_inclusion(:icon, @icons)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  # `data` is the translations map and nothing else: a string or list there
  # would crash every reader, and it is the one castable free-form field.
  defp validate_data_shape(changeset) do
    if valid_data?(get_field(changeset, :data)) do
      changeset
    else
      add_error(changeset, :data, "is invalid")
    end
  end

  defp valid_data?(%{"_primary_language" => primary} = data) do
    is_binary(primary) and String.trim(primary) != "" and is_map(data[primary]) and
      Enum.all?(Map.delete(data, "_primary_language"), fn {_lang, entry} ->
        valid_text_fields?(entry)
      end)
  end

  defp valid_data?(%{} = data), do: valid_text_fields?(data)
  defp valid_data?(_), do: false

  defp valid_text_fields?(%{} = entry) do
    Enum.all?(~w(name _name description _description), fn key ->
      is_nil(entry[key]) or is_binary(entry[key])
    end)
  end

  defp valid_text_fields?(_), do: false

  defp validate_builtin_stays_active(changeset) do
    if changeset.data.builtin and get_field(changeset, :status) == "archived" do
      add_error(changeset, :status, "a built-in role cannot be archived")
    else
      changeset
    end
  end

  # A custom role without a name is a blank badge. A built-in is exempt: its
  # name falls back to the gettext string, so an admin clearing the field
  # simply resets it.
  defp validate_primary_name(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_primary_name(changeset) do
    if changeset.data.builtin do
      changeset
    else
      case PhoenixKitCRM.PartyRoleTypes.name_from_data(get_field(changeset, :data)) do
        nil -> add_error(changeset, :name, "can't be blank")
        _name -> changeset
      end
    end
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec badges() :: [String.t()]
  def badges, do: @badges

  @spec icons() :: [String.t()]
  def icons, do: @icons

  @spec default_badge() :: String.t()
  def default_badge, do: @default_badge

  @spec default_icon() :: String.t()
  def default_icon, do: @default_icon

  @spec key_max() :: pos_integer()
  def key_max, do: @key_max

  @spec key_format() :: Regex.t()
  def key_format, do: @key_format
end
