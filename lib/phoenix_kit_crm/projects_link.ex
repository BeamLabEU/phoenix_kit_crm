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

  @doc "Whether the projects ledger is loaded and takes time entries."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(@ledger) and function_exported?(@ledger, :log_time, 3)
  rescue
    _ -> false
  end

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
