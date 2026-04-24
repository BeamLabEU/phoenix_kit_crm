defmodule PhoenixKitCRM.UserRoleView do
  @moduledoc """
  Context for managing per-user CRM view configuration.

  View config is keyed by user UUID and scope. Scope is either `:companies`
  or `{:role, uuid}`.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.UserRoleViewConfig

  @type scope :: :companies | {:role, binary()}

  @doc """
  Encodes a scope value to its string representation.

  ## Examples

      iex> scope_to_string(:companies)
      "companies"

      iex> scope_to_string({:role, "abc-123"})
      "role:abc-123"
  """
  @spec scope_to_string(scope()) :: String.t()
  def scope_to_string(:companies), do: "companies"
  def scope_to_string({:role, uuid}), do: "role:#{uuid}"

  @doc """
  Decodes a scope string to its term representation.

  ## Examples

      iex> scope_from_string("companies")
      :companies

      iex> scope_from_string("role:abc-123")
      {:role, "abc-123"}
  """
  @spec scope_from_string(String.t()) :: scope()
  def scope_from_string("companies"), do: :companies
  def scope_from_string("role:" <> uuid), do: {:role, uuid}

  @doc """
  Returns the view config for a user and scope.

  Falls back to `default_config/1` when no row exists.

  ## Examples

      iex> get_view_config(user_uuid, :companies)
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

      iex> put_view_config(user_uuid, :companies, %{"columns" => ["name"]})
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

      iex> default_config(:companies)
      %{}

      iex> default_config({:role, "abc-123"})
      %{}
  """
  @spec default_config(scope()) :: map()
  def default_config(_scope), do: %{}
end
