defmodule PhoenixKitCRM.Web.PartyRoleHelpers do
  @moduledoc """
  Shared helpers for the commercial party-role UI (badges on the list pages,
  the Roles checkbox section on the company/contact forms).
  """

  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  alias PhoenixKitCRM.PartyRoles
  alias PhoenixKitCRM.Schemas.PartyRole

  @doc "Human label for a role value."
  def role_label("supplier"), do: gettext("Supplier")
  def role_label("customer"), do: gettext("Customer")
  def role_label("partner"), do: gettext("Partner")
  def role_label("manufacturer"), do: gettext("Manufacturer")
  def role_label(role), do: role

  @doc "daisyUI badge modifier for a role value."
  def role_badge_class("supplier"), do: "badge-info"
  def role_badge_class("customer"), do: "badge-success"
  def role_badge_class("manufacturer"), do: "badge-warning"
  def role_badge_class("partner"), do: "badge-accent"
  def role_badge_class(_), do: "badge-ghost"

  @doc """
  Reads the checked `roles[]` checkboxes from a raw form event payload,
  keeping only known roles (a forged payload can't invent one).
  """
  def selected_roles(payload) when is_map(payload) do
    payload
    |> Map.get("roles", [])
    |> List.wrap()
    |> Enum.filter(&(&1 in PartyRole.roles()))
  end

  def selected_roles(_), do: []

  @doc """
  Active role values currently held by a company/contact — the initial
  checkbox state for the edit forms.
  """
  def active_role_values(roleable) do
    roleable
    |> PartyRoles.list_roles()
    |> Enum.filter(& &1.is_active)
    |> Enum.map(& &1.role)
  end

  @doc """
  Reconciles checkbox state with stored roles: grants what's newly checked,
  revokes active roles that were unchecked. Both operations are idempotent,
  so re-saving an unchanged form is a no-op.

  Returns `:ok` when every role reconciled, or `{:partial, failed_roles}` if
  one or more grant/revoke calls failed (each is also logged). Callers should
  surface a warning instead of reporting unqualified success — a checked role
  that silently didn't apply is a real user-visible correctness gap.

  Pass the acting user's uuid as `actor_uuid` so grant/revoke activity log
  entries record who made the change (mirrors every other logged CRM
  mutation instead of landing with `actor_uuid: nil`).
  """
  @spec sync_roles(struct(), [String.t()], UUIDv7.t() | String.t() | nil) ::
          :ok | {:partial, [String.t()]}
  def sync_roles(roleable, selected, actor_uuid \\ nil) when is_list(selected) do
    # One transaction: a crash or dropped connection halfway through used to
    # leave an arbitrary prefix of the checkboxes applied, with the form still
    # showing what the user asked for. Either every role matches the form or
    # none of them moved.
    case PhoenixKit.RepoHelper.repo().transaction(fn ->
           reconcile(roleable, selected, actor_uuid)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:partial, roles}} -> {:partial, roles}
      {:error, _reason} -> {:partial, PartyRole.roles()}
    end
  end

  defp reconcile(roleable, selected, actor_uuid) do
    failed =
      Enum.reduce(PartyRole.roles(), [], fn role, failed ->
        result =
          cond do
            role in selected ->
              PartyRoles.grant_role(roleable, role, %{}, actor_uuid: actor_uuid)

            PartyRoles.has_role?(roleable, role) ->
              PartyRoles.revoke_role(roleable, role, actor_uuid: actor_uuid)

            true ->
              :ok
          end

        case result do
          :ok ->
            failed

          {:ok, _} ->
            failed

          other ->
            Logger.warning("[CRM] party role sync failed for #{inspect(role)}: #{inspect(other)}")
            [role | failed]
        end
      end)

    case failed do
      [] -> :ok
      roles -> {:partial, Enum.reverse(roles)}
    end
  end
end
