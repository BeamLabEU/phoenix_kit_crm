defmodule PhoenixKitCRM.Web.PartyRoleHelpers do
  @moduledoc """
  Shared helpers for the commercial party-role UI (badges on the list pages,
  the Roles checkbox section on the company/contact forms).
  """

  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  alias PhoenixKitCRM.{PartyRoles, PartyRoleTypes}
  alias PhoenixKitCRM.Schemas.PartyRoleType

  @doc """
  Human label for a role key, in the viewer's language. `types` is the
  `PartyRoleTypes.types_by_key/0` map the page loaded once.
  """
  def role_label(types, role, lang \\ nil), do: PartyRoleTypes.label(types, role, lang)

  @doc "daisyUI badge modifier for a role key. See `role_label/2`."
  def role_badge_class(types, role), do: PartyRoleTypes.badge_class(types, role)

  @doc """
  The role types a company/contact form offers: every active type, plus any
  archived type the party still holds -- so an archived role can be unticked
  but never newly ticked. Pass `nil` for a record not yet saved.
  """
  @spec form_types(struct() | nil) :: [PartyRoleType.t()]
  def form_types(roleable \\ nil) do
    held = if roleable && roleable.uuid, do: active_role_values(roleable), else: []

    Enum.filter(PartyRoleTypes.list_types(), fn type ->
      type.status == "active" or type.key in held
    end)
  end

  @doc """
  Reads the checked `roles[]` checkboxes from a raw form event payload,
  keeping only the roles the form offered (`role_types`, from `form_types/1`)
  -- a forged payload can't invent one.
  """
  def selected_roles(payload, role_types) when is_map(payload) do
    offered = MapSet.new(role_types, & &1.key)

    payload
    |> Map.get("roles", [])
    |> List.wrap()
    |> Enum.filter(&MapSet.member?(offered, &1))
  end

  def selected_roles(_, _), do: []

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
      {:error, _reason} -> {:partial, offered_keys(roleable)}
    end
  end

  # Only the roles the form offered are reconciled: an archived role the party
  # holds is shown (so it can be unticked); one the form never showed must not
  # be revoked just because it isn't ticked.
  defp offered_keys(roleable), do: Enum.map(form_types(roleable), & &1.key)

  defp reconcile(roleable, selected, actor_uuid) do
    failed =
      Enum.reduce(offered_keys(roleable), [], fn role, failed ->
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
