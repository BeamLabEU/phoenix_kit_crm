defmodule PhoenixKitCRM.SoftDelete do
  @moduledoc """
  Status-column soft-delete shared by `Contacts` and `Companies`.

  Trashing stashes the record's current status in
  `metadata["trashed_from_status"]` and sets `status` to the schema's
  soft-delete sentinel; restoring reverses it (falling back to `"active"` if the
  stashed status is no longer valid). Works on any schema with a `status` string
  column and a `metadata` map column.

  Each is ONE `UPDATE` whose `SET` expressions read the row as it is at that
  moment, never the caller's copy of it. A whole-map write built from a struct
  loaded earlier would erase a key another session wrote since — the avatar
  pointer `Attachments.set_avatar/3` writes in place, for one. The status guard
  sits in the `WHERE`, so two sessions trashing the same record get one
  `{:ok, _}` and one `{:error, :already_trashed}`.

  The caller's struct comes back with the fresh `status` and `metadata` and
  its preloads as they were.
  """

  import Ecto.Query

  @stash_key "trashed_from_status"

  @doc """
  Trashes `record`: stashes its current status under `#{@stash_key}` and sets
  `status` to `sentinel`. `{:error, :already_trashed}` when the row already
  carries the sentinel, `{:error, :not_found}` when it is gone.
  """
  @spec trash(module(), struct(), String.t()) ::
          {:ok, struct()} | {:error, :already_trashed | :not_found}
  def trash(repo, %schema{uuid: uuid} = record, sentinel) do
    query =
      from(r in schema,
        where: r.uuid == ^uuid and r.status != ^sentinel,
        update: [
          set: [
            status: ^sentinel,
            metadata:
              fragment(
                "jsonb_set(coalesce(?, '{}'::jsonb), '{trashed_from_status}', to_jsonb(?::text))",
                r.metadata,
                r.status
              )
          ]
        ],
        select: {r.status, r.metadata}
      )

    case repo.update_all(query, []) do
      {1, [{status, metadata}]} ->
        {:ok, %{record | status: status, metadata: metadata}}

      {0, _} ->
        if repo.exists?(from(r in schema, where: r.uuid == ^uuid)),
          do: {:error, :already_trashed},
          else: {:error, :not_found}
    end
  end

  @doc """
  Restores `record`: pops the stashed status (or `"active"` if it is not one of
  `valid_statuses`), clearing the stash key and nothing else.
  `{:error, :not_trashed}` when the row does not carry the sentinel.
  """
  @spec restore(module(), struct(), String.t(), [String.t()]) ::
          {:ok, struct()} | {:error, :not_trashed}
  def restore(repo, %schema{uuid: uuid} = record, sentinel, valid_statuses) do
    query =
      from(r in schema,
        where: r.uuid == ^uuid and r.status == ^sentinel,
        update: [
          set: [
            status:
              fragment(
                "CASE WHEN ? ->> 'trashed_from_status' = ANY(?) THEN ? ->> 'trashed_from_status' ELSE 'active' END",
                r.metadata,
                type(^valid_statuses, {:array, :string}),
                r.metadata
              ),
            metadata: fragment("coalesce(?, '{}'::jsonb) - 'trashed_from_status'", r.metadata)
          ]
        ],
        select: {r.status, r.metadata}
      )

    case repo.update_all(query, []) do
      {1, [{status, metadata}]} -> {:ok, %{record | status: status, metadata: metadata}}
      {0, _} -> {:error, :not_trashed}
    end
  end
end
