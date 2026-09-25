defmodule PhoenixKitCRM.ServerOwnedMetadata do
  @moduledoc """
  Keeps the metadata keys the module writes itself out of the public
  changesets.

  `metadata` is castable on contacts and companies so a host can keep its own
  keys there, but two of them are server-owned: `avatar_uuid`, written only by
  `PhoenixKitCRM.Attachments.set_avatar/3` after it has checked the file is the
  record's own image, and `trashed_from_status`, written only by
  `PhoenixKitCRM.SoftDelete`. A metadata map from params — or from a stale
  struct — must be able neither to set nor to clear them.

  The keys are re-read from the row, under its lock, inside the write's own
  transaction, so the merge is against what the row holds at that moment
  rather than what the caller loaded earlier.
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @keys ~w(avatar_uuid trashed_from_status)

  @doc "The server-owned metadata keys."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  When `changeset` changes `:metadata`, drops the server-owned keys from the
  new map and puts back the row's own values for them at write time.
  """
  @spec keep(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def keep(%Ecto.Changeset{} = changeset) do
    case fetch_change(changeset, :metadata) do
      {:ok, new} when is_map(new) ->
        prepare_changes(changeset, fn cs ->
          put_change(cs, :metadata, Map.merge(without_owned(new), owned_now(cs)))
        end)

      _ ->
        changeset
    end
  end

  # Atom keys would be stored under the same JSON names, so both spellings go.
  defp without_owned(map) do
    Map.reject(map, fn {k, _} -> (is_atom(k) or is_binary(k)) and to_string(k) in @keys end)
  end

  defp owned_now(%Ecto.Changeset{data: %schema{uuid: uuid}, repo: repo}) when is_binary(uuid) do
    query = from(r in schema, where: r.uuid == ^uuid, select: r.metadata, lock: "FOR UPDATE")

    case repo.one(query) do
      %{} = metadata -> Map.take(metadata, @keys)
      _ -> %{}
    end
  end

  defp owned_now(_new_record), do: %{}
end
