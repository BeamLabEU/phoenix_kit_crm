defmodule PhoenixKitCRM.ExternalRef do
  @moduledoc """
  The id an outside system knows a company or contact by (V11):
  `external_source` names the system (`"lab2"`, `"hubspot"`,
  `"äriregister"` …) and `external_id` is its id there. Both are free
  text; blank means none. The source is stored trimmed and lowercased
  (`"HubSpot "` is `"hubspot"`), and the lookups lowercase it the same
  way; the id is kept as given, only trimmed.

  A trashed record keeps its reference, on purpose: the lookup still finds
  it, so a sync restores it instead of creating a second record, and the
  pair stays taken until the record is deleted for good.

  A pair is unique per table — a partial unique index on
  `(external_source, external_id) WHERE external_id IS NOT NULL` — and an id
  needs its source (a CHECK), so an importer can always find the record it
  wrote last time: `PhoenixKitCRM.Companies.get_company_by_external_ref/2`,
  `PhoenixKitCRM.Contacts.get_contact_by_external_ref/2` and their batched
  `map_*` forms. The index covers trashed rows too: a trashed company keeps
  its reference, and the lookup finds it, so a sync can restore it instead
  of creating a second one.
  """

  use Gettext, backend: PhoenixKitCRM.Gettext
  import Ecto.Changeset

  @source_max 50
  @id_max 255

  @doc "The longest `external_source` (the column's limit)."
  @spec source_max() :: pos_integer()
  def source_max, do: @source_max

  @doc """
  Casts and checks the two fields on a company or contact changeset: both
  trimmed (blank → nil), within the columns' lengths, an id only with a
  source, and the index's uniqueness mapped to an error on `:external_id`.
  `index` is the unique index's name.

  An integer id is taken as its decimal text (`42` → `"42"`), the same way
  the lookups read one. Lengths count code points, as `varchar(n)` does.
  The CHECK is mapped too: an update from a stale struct (the source looks
  unchanged, so only the id is written, onto a row whose source was
  cleared meanwhile) comes back as an error instead of raising.
  """
  @spec changeset(Ecto.Changeset.t(), map(), atom()) :: Ecto.Changeset.t()
  def changeset(changeset, attrs, index) do
    changeset
    |> cast(integer_ids_to_text(attrs), [:external_source, :external_id])
    |> update_change(:external_source, &normalize_source/1)
    |> update_change(:external_id, &blank_to_nil/1)
    |> validate_length(:external_source, max: @source_max, count: :codepoints)
    |> validate_length(:external_id, max: @id_max, count: :codepoints)
    |> validate_source_present()
    |> check_constraint(:external_source,
      name: "#{changeset.data.__meta__.source}_external_source_check",
      message: source_needed_message()
    )
    |> unique_constraint(:external_id,
      name: index,
      message: taken_message()
    )
  end

  defp integer_ids_to_text(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when key in [:external_id, "external_id"] and is_integer(value) ->
        {key, Integer.to_string(value)}

      pair ->
        pair
    end)
  end

  defp integer_ids_to_text(attrs), do: attrs

  # Translated when the changeset is built (the caller's locale), through
  # this module's own catalogue.
  defp source_needed_message, do: gettext("can't be blank when an external id is set")

  defp taken_message,
    do: gettext("is already used by another record from this source (perhaps one in the trash)")

  @doc "Normalizes a source the way the changeset stores it: trimmed, lowercase."
  @spec normalize_source(term()) :: String.t() | nil
  def normalize_source(value) when is_binary(value) do
    case blank_to_nil(value) do
      nil -> nil
      source -> String.downcase(source)
    end
  end

  def normalize_source(_), do: nil

  @doc "Normalizes one lookup id the way the changeset stores it."
  @spec normalize(term()) :: String.t() | nil
  def normalize(value) when is_binary(value), do: blank_to_nil(value)
  def normalize(value) when is_integer(value), do: Integer.to_string(value)
  def normalize(_), do: nil

  defp validate_source_present(changeset) do
    if get_field(changeset, :external_id) && is_nil(get_field(changeset, :external_source)) do
      add_error(changeset, :external_source, source_needed_message())
    else
      changeset
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
