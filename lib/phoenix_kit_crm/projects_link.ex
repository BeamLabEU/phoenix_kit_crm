defmodule PhoenixKitCRM.ProjectsLink do
  # `apply/3` on purpose: `phoenix_kit_projects` is not a dependency of this
  # module (the projects hub discovers the CRM's extension at runtime, not
  # the other way round), so a direct call would be a compile-time
  # "undefined module" warning on every install without it. Every call is
  # gated by `function_exported?/3`, exactly like `StaffLink`.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Optional, soft integration with `phoenix_kit_projects`: the one place the
  CRM writes INTO the projects module — an attendee's minutes on a meeting
  logged from a project's Client tab, as entries in that project's work
  ledger. The CRM is the record of the meeting; the ledger is the record of
  the time. Everything here degrades to `{:error, :unavailable}` when the
  projects module is absent, so the Client tab (which only exists when it
  is present) is the only caller that ever sees a success.
  """

  require Logger

  @ledger PhoenixKitProjects.Ledger
  @events PhoenixKitProjects.ProjectEvents

  @doc "Whether the projects ledger is loaded and takes time entries."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(@ledger) and function_exported?(@ledger, :log_time, 3)
  rescue
    _ -> false
  end

  @doc """
  The time already in the project's ledger against one interaction, as
  `[%{actor_kind, actor_uuid, minutes, billable}]` — what an edit must not
  log twice. The ledger filters on the metadata where it can; the filter
  is applied here too, so an older ledger that ignores the option still
  answers correctly. Empty when the projects module is absent.
  """
  @spec list_time(binary(), binary()) :: [map()]
  def list_time(project_uuid, interaction_uuid)
      when is_binary(project_uuid) and is_binary(interaction_uuid) do
    if Code.ensure_loaded?(@ledger) and function_exported?(@ledger, :list_entries, 2) do
      @ledger
      |> apply(:list_entries, [
        project_uuid,
        [limit: 500, metadata: %{"interaction_uuid" => interaction_uuid}]
      ])
      |> Enum.filter(fn e ->
        Map.get(e, :kind) == "time" and
          (Map.get(e, :metadata) || %{})["interaction_uuid"] == interaction_uuid
      end)
      |> Enum.map(fn e ->
        %{
          uuid: Map.get(e, :uuid),
          actor_kind: Map.get(e, :actor_kind),
          actor_uuid: Map.get(e, :actor_uuid),
          minutes: e |> Map.get(:amount) |> to_minutes(),
          billable: Map.get(e, :billable) == true
        }
      end)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[CRM] ledger read failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Amends one time entry's minutes (and its billable flag through
  `billable:`), as the ledger's `update_time/3` does — an attendee's figure
  changed in an edit of the meeting.
  """
  @spec update_time(binary(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_time(entry_uuid, minutes, opts \\ [])
      when is_binary(entry_uuid) and is_integer(minutes) and minutes > 0 do
    if Code.ensure_loaded?(@ledger) and function_exported?(@ledger, :update_time, 3) do
      apply(@ledger, :update_time, [entry_uuid, minutes, opts])
    else
      {:error, :unavailable}
    end
  rescue
    e ->
      Logger.warning("[CRM] ledger amend failed: #{Exception.message(e)}")
      {:error, :unavailable}
  end

  @doc "Removes one time entry (an attendee's figure set to 0 in an edit)."
  @spec delete_time(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_time(entry_uuid, opts \\ []) when is_binary(entry_uuid) do
    if Code.ensure_loaded?(@ledger) and function_exported?(@ledger, :delete_entry, 2) do
      apply(@ledger, :delete_entry, [entry_uuid, opts])
    else
      {:error, :unavailable}
    end
  rescue
    e ->
      Logger.warning("[CRM] ledger delete failed: #{Exception.message(e)}")
      {:error, :unavailable}
  end

  defp to_minutes(%Decimal{} = d), do: d |> Decimal.round() |> Decimal.to_integer()
  defp to_minutes(n) when is_integer(n), do: n
  defp to_minutes(n) when is_float(n), do: round(n)
  defp to_minutes(_), do: 0

  @doc """
  The project's events (the plan: meetings as scheduled), newest first,
  for the composer's "Planned as" pick. Empty when the projects module is
  absent. Options go to the projects module's `list_for_project/2`.
  """
  @spec list_events(binary(), keyword()) :: [map()]
  def list_events(project_uuid, opts \\ []) when is_binary(project_uuid) do
    if Code.ensure_loaded?(@events) and function_exported?(@events, :list_for_project, 2) do
      @events |> apply(:list_for_project, [project_uuid, opts]) |> Enum.reverse()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Plans a meeting: a project event (`title`, `starts_at`, optional
  `location`, no end — nobody knows how long it will take) created by the
  projects module, which logs it and shows it on the project's calendar.
  """
  @spec create_event(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_event(project_uuid, attrs, opts \\ [])
      when is_binary(project_uuid) and is_map(attrs) do
    if Code.ensure_loaded?(@events) and function_exported?(@events, :create, 3) do
      apply(@events, :create, [%{uuid: project_uuid}, attrs, opts])
    else
      {:error, :unavailable}
    end
  rescue
    e ->
      Logger.warning("[CRM] event create failed: #{Exception.message(e)}")
      {:error, :unavailable}
  end

  @doc "One event of the project, or nil."
  @spec get_event(binary(), binary()) :: map() | nil
  def get_event(project_uuid, event_uuid)
      when is_binary(project_uuid) and is_binary(event_uuid) do
    if Code.ensure_loaded?(@events) and function_exported?(@events, :get, 2),
      do: apply(@events, :get, [project_uuid, event_uuid])
  rescue
    _ -> nil
  end

  def get_event(_, _), do: nil

  @doc """
  One ledger entry of `minutes` on `project_uuid`, with the ledger's own
  `log_time/3` options (`:actor_kind`, `:actor_uuid`, `:note`, `:billable`,
  `:started_at`, `:ended_at`, `:metadata`). Returns what the ledger returns,
  or `{:error, :unavailable}`.
  """
  @spec log_time(binary(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def log_time(project_uuid, minutes, opts)
      when is_binary(project_uuid) and is_integer(minutes) do
    if available?() do
      apply(@ledger, :log_time, [project_uuid, minutes, opts])
    else
      {:error, :unavailable}
    end
  rescue
    e ->
      Logger.warning("[CRM] ledger write failed: #{Exception.message(e)}")
      {:error, :unavailable}
  end
end
