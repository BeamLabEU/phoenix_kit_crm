defmodule PhoenixKitCRM.Paths do
  @moduledoc """
  Centralized path helpers for the CRM module. All paths go through
  `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/crm"
  @settings_base "/admin/settings/crm"

  def index, do: Routes.path(@base)
  def settings, do: Routes.path(@settings_base)
end
