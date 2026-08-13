defmodule PhoenixKitCRM.Web.Components.MirrorPanel do
  @moduledoc """
  The "mirror account" status + actions block, shared by the Company and
  Contact forms (Tasks G/H) — the CRM-record side of the CRM ↔ system-user
  mirror (`PhoenixKitCRM.Mirror`, `Companies`/`Contacts` "connect"
  contexts).

  Pure presentation function component. The consumer LiveView owns all
  state (`:linked_user`, `:can_link`) and implements the events this
  panel fires:

      mirror_unlink        — linked state, "Unlink" clicked
      mirror_create        — unlinked state, "Create mirror user" clicked
      mirror_open_picker   — unlinked state, "Link existing…" clicked

  ## Usage

      <.mirror_panel
        kind={:company}
        linked_user={@linked_user}
        can_link={@org_accounts_enabled?}
        account_path={@linked_user && Paths.user_view(@linked_user.uuid)}
      />
  """

  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKit.Users.Auth.User

  attr(:kind, :atom, required: true, values: [:company, :contact])
  attr(:linked_user, :any, default: nil)
  attr(:can_link, :boolean, default: true)
  attr(:account_path, :string, default: nil)

  def mirror_panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 p-4 space-y-3" data-testid="mirror-panel">
      <div class="flex items-center justify-between gap-2">
        <span class="text-sm font-semibold">{gettext("Mirror account")}</span>
        <span :if={@linked_user} class="badge badge-success badge-sm">
          {badge_label(@kind)}
        </span>
      </div>

      <div :if={@linked_user} class="space-y-2">
        <div>
          <div class="text-sm font-medium">{display_name(@linked_user)}</div>
          <div class="text-xs text-base-content/60">{@linked_user.email}</div>
        </div>
        <div class="flex flex-wrap gap-2">
          <.link :if={@account_path} navigate={@account_path} class="btn btn-ghost btn-xs">
            {gettext("View account")}
          </.link>
          <.button phx-click="mirror_unlink" variant="ghost" size="xs">
            {gettext("Unlink")}
          </.button>
        </div>
      </div>

      <div :if={!@linked_user && @can_link} class="flex flex-wrap gap-2">
        <.button phx-click="mirror_create" variant="primary" size="xs">
          {gettext("Create mirror user")}
        </.button>
        <.button phx-click="mirror_open_picker" variant="outline" size="xs">
          {gettext("Link existing…")}
        </.button>
      </div>

      <div :if={!@linked_user && !@can_link && @kind == :company} class="text-xs text-base-content/50">
        {gettext("Enable organization accounts in Settings to mirror a company.")}
      </div>
    </div>
    """
  end

  defp badge_label(:contact), do: gettext("Login")
  defp badge_label(:company), do: gettext("Mirror")

  @doc """
  Same precedence `Andi.CRMBridge.user_display_name/1` uses for the
  reverse (user -> contact) direction: organization name when set, else
  the trimmed first+last name, else the email. Public — reused by
  `CompanyShowLive`'s read-only mirror status row (Task J) so both
  surfaces render the same name for the same user.
  """
  @spec display_name(User.t()) :: String.t()
  def display_name(%User{} = user) do
    personal = String.trim("#{user.first_name} #{user.last_name}")

    cond do
      user.account_type == "organization" && is_binary(user.organization_name) &&
          user.organization_name != "" ->
        user.organization_name

      personal != "" ->
        personal

      true ->
        user.email
    end
  end
end
