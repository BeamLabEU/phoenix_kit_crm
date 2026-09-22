defmodule PhoenixKitCRM.ActivityLogAssertions do
  @moduledoc """
  Helpers for asserting activity log entries landed with the right action, actor,
  resource, and metadata shape. Imported into `PhoenixKitCRM.LiveCase` so every
  DB-backed LiveView test can reach them.
  """

  import ExUnit.Assertions

  alias Ecto.Adapters.SQL
  alias PhoenixKitCRM.Test.Repo, as: TestRepo

  @doc """
  Asserts that exactly one activity row exists for `action` matching the given
  criteria, and returns it.

  ## Options

    * `:module` — match on the module key the row was logged under
    * `:resource_uuid` — match on `resource_uuid`
    * `:actor_uuid` — match on `actor_uuid`
    * `:metadata_has` — assert each key/value pair is present in `metadata`
      (JSONB subset match; extra keys are fine)
  """
  def assert_activity_logged(action, opts \\ []) do
    rows = query_activities(action)
    matching = Enum.filter(rows, &matches_opts?(&1, opts))

    case matching do
      [row] ->
        row

      [] ->
        flunk("""
        Expected one activity row for #{inspect(action)}, found none matching the criteria.
        Rows for this action: #{inspect(rows)}
        Criteria: #{inspect(opts)}
        """)

      many ->
        flunk("""
        Expected exactly one activity row for #{inspect(action)}, found #{length(many)}.
        Matches: #{inspect(many)}
        """)
    end
  end

  @doc "Asserts no activity row exists for `action` (given the same optional filters)."
  def refute_activity_logged(action, opts \\ []) do
    rows = query_activities(action)

    case Enum.filter(rows, &matches_opts?(&1, opts)) do
      [] -> :ok
      found -> flunk("Expected no activity row for #{inspect(action)}, found #{length(found)}.")
    end
  end

  # ── internals ──────────────────────────────────────────────────

  defp query_activities(action) do
    query =
      "SELECT action, module, actor_uuid, resource_type, resource_uuid, metadata " <>
        "FROM phoenix_kit_activities WHERE action = $1 ORDER BY inserted_at DESC"

    %{rows: rows, columns: cols} = SQL.query!(TestRepo, query, [action])

    Enum.map(rows, fn row ->
      cols |> Enum.zip(row) |> Map.new(fn {k, v} -> {String.to_atom(k), normalize(v)} end)
    end)
  end

  defp normalize({:ok, uuid}) when is_binary(uuid), do: uuid
  defp normalize(value), do: value

  defp matches_opts?(row, opts) do
    match_opt(opts, :module, &(row.module == &1)) and
      match_opt(opts, :resource_uuid, &uuid_match?(row.resource_uuid, &1)) and
      match_opt(opts, :actor_uuid, &uuid_match?(row.actor_uuid, &1)) and
      match_opt(opts, :metadata_has, &metadata_subset?(row.metadata, &1))
  end

  defp match_opt(opts, key, check_fun) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, value} -> check_fun.(value)
    end
  end

  defp metadata_subset?(metadata, subset) do
    metadata = metadata || %{}
    Enum.all?(subset, fn {k, v} -> Map.get(metadata, k) == v end)
  end

  defp uuid_match?(nil, nil), do: true
  defp uuid_match?(nil, _), do: false
  defp uuid_match?(_, nil), do: false

  defp uuid_match?(row_uuid, expected) when is_binary(row_uuid) and byte_size(row_uuid) == 16 do
    {:ok, encoded} = Ecto.UUID.load(row_uuid)
    encoded == expected
  end

  defp uuid_match?(row_uuid, expected) when is_binary(row_uuid), do: row_uuid == expected
end
