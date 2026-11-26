defmodule PhoenixKitCRM.ExternalRef do
  @moduledoc """
  The id an outside system knows a company or contact by (V11):
  `external_source` names the system (`"lab2"`, `"hubspot"`,
  `"äriregister"` …) and `external_id` is its id there. Both are free
  text; blank means none.

  A pair is unique per table — a partial unique index on
  `(external_source, external_id) WHERE external_id IS NOT NULL` — and an id
  needs its source (a CHECK), so an importer can always find the record it
  wrote last time: `PhoenixKitCRM.Companies.get_company_by_external_ref/2`,
  `PhoenixKitCRM.Contacts.get_contact_by_external_ref/2` and their batched
  `map_*` forms. The index covers trashed rows too: a trashed company keeps
  its reference, and the lookup finds it, so a sync can restore it instead
  of creating a second one.
  """

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
  """
  @spec changeset(Ecto.Changeset.t(), map(), atom()) :: Ecto.Changeset.t()
  def changeset(changeset, attrs, index) do
    changeset
    |> cast(attrs, [:external_source, :external_id])
    |> update_change(:external_source, &blank_to_nil/1)
    |> update_change(:external_id, &blank_to_nil/1)
    |> validate_length(:external_source, max: @source_max)
    |> validate_length(:external_id, max: @id_max)
    |> validate_source_present()
    |> unique_constraint(:external_id,
      name: index,
      message: "is already used by another record from this source"
    )
  end

  @doc "Normalizes one lookup value the way the changeset stores it."
  @spec normalize(term()) :: String.t() | nil
  def normalize(value) when is_binary(value), do: blank_to_nil(value)
  def normalize(value) when is_integer(value), do: Integer.to_string(value)
  def normalize(_), do: nil

  defp validate_source_present(changeset) do
    if get_field(changeset, :external_id) && is_nil(get_field(changeset, :external_source)) do
      add_error(changeset, :external_source, "can't be blank when an external id is set")
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
