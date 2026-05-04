defmodule PhoenixKitCRM.UserRoleView do
  @moduledoc """
  Context for managing per-user CRM view configuration.

  View config is keyed by user UUID and scope. Scope is either `:organizations`
  or `{:role, uuid}`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.UserRoleViewConfig

  @type scope :: :organizations | {:role, binary()}

  @doc """
  Encodes a scope value to its string representation.

  ## Examples

      iex> scope_to_string(:organizations)
      "organizations"

      iex> scope_to_string({:role, "abc-123"})
      "role:abc-123"
  """
  @spec scope_to_string(scope()) :: String.t()
  def scope_to_string(:organizations), do: "organizations"
  def scope_to_string({:role, uuid}), do: "role:#{uuid}"

  @doc """
  Decodes a scope string to its term representation.

  Falls back to `:organizations` and logs a warning on malformed input —
  this defends against data corruption (manual DB edits, broken imports)
  causing render-time `FunctionClauseError`s deep in a LiveView.

  ## Examples

      iex> scope_from_string("organizations")
      :organizations

      iex> scope_from_string("role:abc-123")
      {:role, "abc-123"}
  """
  @spec scope_from_string(String.t()) :: scope()
  def scope_from_string("organizations"), do: :organizations
  def scope_from_string("role:" <> uuid), do: {:role, uuid}

  def scope_from_string(other) do
    Logger.warning(
      "[PhoenixKitCRM] Unknown scope string #{inspect(other)} — falling back to :organizations"
    )

    :organizations
  end

  @doc """
  Returns the view config for a user and scope.

  Falls back to `default_config/1` when no row exists.

  ## Examples

      iex> get_view_config(user_uuid, :organizations)
      %{}
  """
  @spec get_view_config(binary(), scope()) :: map()
  def get_view_config(user_uuid, scope) when is_binary(user_uuid) do
    repo = RepoHelper.repo()
    scope_str = scope_to_string(scope)

    case repo.get_by(UserRoleViewConfig, user_uuid: user_uuid, scope: scope_str) do
      nil -> default_config(scope)
      config -> config.view_config
    end
  end

  @doc """
  Upserts the view config for a user and scope.

  ## Examples

      iex> put_view_config(user_uuid, :organizations, %{"columns" => ["organization_name"]})
      {:ok, %UserRoleViewConfig{}}
  """
  @spec put_view_config(binary(), scope(), map()) ::
          {:ok, UserRoleViewConfig.t()} | {:error, Ecto.Changeset.t()}
  def put_view_config(user_uuid, scope, config)
      when is_binary(user_uuid) and is_map(config) do
    repo = RepoHelper.repo()
    scope_str = scope_to_string(scope)

    %UserRoleViewConfig{}
    |> UserRoleViewConfig.changeset(%{
      user_uuid: user_uuid,
      scope: scope_str,
      view_config: config
    })
    |> repo.insert(
      on_conflict: {:replace, [:view_config, :updated_at]},
      conflict_target: [:user_uuid, :scope]
    )
  end

  @doc """
  Returns the default view config for a scope.

  ## Examples

      iex> default_config(:organizations)
      %{}

      iex> default_config({:role, "abc-123"})
      %{}
  """
  @spec default_config(scope()) :: map()
  def default_config(_scope), do: %{}
end
