defmodule PhoenixKitCRM.Activity do
  @moduledoc """
  CRM's activity logging: `PhoenixKit.Activity.log/3` under the `"crm"`
  module key, which never crashes the caller. Who is acting is read by
  `PhoenixKitWeb.Actor` — the scope first, the bare current user second —
  the same way every module reads it.

  Action strings follow `"crm.<resource>_<verb>"`.
  """

  @module "crm"

  @doc "Logs a CRM activity entry. See `PhoenixKit.Activity.log/3` for the options."
  @spec log(String.t(), keyword()) :: {:ok, PhoenixKit.Activity.Entry.t()} | {:error, term()}
  def log(action, opts) when is_binary(action) and is_list(opts),
    do: PhoenixKit.Activity.log(@module, action, opts)

  @doc "The acting user's uuid, or `nil`. See `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t() | map()) :: String.t() | nil
  defdelegate actor_uuid(source), to: PhoenixKitWeb.Actor, as: :uuid

  @doc "`[actor_uuid: uuid]`, or `[]` when nobody is signed in. See `PhoenixKitWeb.Actor.opts/1`."
  @spec actor_opts(Phoenix.LiveView.Socket.t() | map()) :: keyword()
  defdelegate actor_opts(source), to: PhoenixKitWeb.Actor, as: :opts
end
