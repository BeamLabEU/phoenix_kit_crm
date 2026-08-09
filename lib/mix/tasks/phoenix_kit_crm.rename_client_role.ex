defmodule Mix.Tasks.PhoenixKitCrm.RenameClientRole do
  @shortdoc "Rename legacy `client` party roles to `customer`"

  @moduledoc """
  One-time data migration for the `client` → `customer` party-role rename.

  0.2.x granted the commercial roles `supplier` / `client` / `partner`. The
  middle one was renamed to `customer` in 0.4.0, but only in code — rows
  already written by an earlier version keep `role = "client"` and become
  unmanageable: invisible under the Customers filter, absent from the
  company/contact role checkboxes, and rendered as a raw grey badge. This task
  rewrites them.

  Rows for a party that already holds `customer` are deleted rather than
  renamed (the `(roleable_type, roleable_uuid, role)` unique index forbids the
  duplicate, and the newer row wins). Everything runs in one transaction and
  is idempotent — a second run reports nothing to do.

  ## Usage

      mix phoenix_kit_crm.rename_client_role           # dry-run
      mix phoenix_kit_crm.rename_client_role --apply   # write

  """

  use Mix.Task

  alias PhoenixKitCRM.PartyRoles

  @impl Mix.Task
  def run(args) do
    apply? = "--apply" in args

    Mix.Task.run("app.start")

    case PartyRoles.count_legacy_client_roles() do
      0 ->
        Mix.shell().info(~s|No legacy "client" party roles found — nothing to do.|)

      _count when apply? ->
        %{renamed: renamed, dropped: dropped} = PartyRoles.rename_legacy_client_roles()

        Mix.shell().info(
          ~s|Renamed #{renamed} "client" role(s) to "customer"; | <>
            ~s|dropped #{dropped} duplicate(s) whose party already held "customer".|
        )

      count ->
        Mix.shell().info(
          ~s|#{count} legacy "client" party role(s) found. | <>
            ~s|Re-run with --apply to rewrite them as "customer".|
        )
    end
  end
end
