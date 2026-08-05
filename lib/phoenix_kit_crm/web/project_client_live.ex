defmodule PhoenixKitCRM.Web.ProjectClientLive do
  @moduledoc """
  The CRM **Client** tab for the `phoenix_kit_projects` hub — this module's
  `phoenix_kit_project_extensions/0` contribution (see that function in
  `PhoenixKitCRM`).

  Rendered by the projects hub via `live_render` with the hub's
  embed-session contract: `"project_uuid"` (the host project),
  `"config"` (this instance's config — `company_uuid` links the client),
  `"current_user_uuid"` / `"locale"`. Linkage is CONFIG-based — no FK, no
  dependency on the projects package; the admin picks the company uuid in
  the project's Modules panel.

  Shows the linked company card, its member contacts, and the most recent
  interactions across those members (the company's aggregated feed), with
  link-outs to the CRM admin. Read-only here — mutations live in CRM.

  Off-router-mountable: no `handle_params/3` (the hub's hard requirement).
  """

  use Phoenix.LiveView

  alias PhoenixKitCRM.{Companies, Interactions, Paths}

  @recent_limit 5

  @impl true
  def mount(_params, session, socket) do
    maybe_put_locale(session)

    company_uuid = get_in(session, ["config", "company_uuid"])
    company = company_uuid && safe(fn -> Companies.get_company(company_uuid) end)

    {memberships, recent} =
      if company do
        memberships = safe(fn -> Companies.list_memberships(company.uuid) end) || []

        contact_uuids =
          memberships |> Enum.map(& &1.contact_uuid) |> Enum.reject(&is_nil/1)

        recent =
          (safe(fn -> Interactions.list_for_contacts(contact_uuids) end) || [])
          |> Enum.take(@recent_limit)

        {memberships, recent}
      else
        {[], []}
      end

    {:ok,
     assign(socket,
       project_uuid: session["project_uuid"],
       company: company,
       memberships: memberships,
       recent: recent
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= if @company do %>
        <div class="card border border-base-200 bg-base-100">
          <div class="card-body py-4 gap-2">
            <div class="flex items-center gap-3">
              <div class="avatar placeholder">
                <div class="bg-primary/10 text-primary rounded-full w-10 h-10">
                  <span class="text-sm font-bold">{String.first(@company.name || "?")}</span>
                </div>
              </div>
              <div class="min-w-0 grow">
                <h3 class="font-semibold truncate">{@company.name}</h3>
                <p class="text-xs opacity-60">
                  {ngettext_members(length(@memberships))}
                </p>
              </div>
              <.link navigate={Paths.company(@company.uuid)} class="btn btn-ghost btn-sm gap-1">
                Open in CRM
              </.link>
            </div>
          </div>
        </div>

        <div :if={@recent != []} class="card border border-base-200 bg-base-100">
          <div class="card-body py-4 gap-2">
            <h4 class="text-sm font-semibold opacity-70">Recent interactions</h4>
            <div class="divide-y divide-base-200">
              <div :for={interaction <- @recent} class="py-2 flex items-baseline gap-2 text-sm">
                <span class="badge badge-ghost badge-xs shrink-0">{interaction.kind}</span>
                <span class="truncate min-w-0">{interaction.subject || "(no subject)"}</span>
              </div>
            </div>
          </div>
        </div>

        <div :if={@recent == []} class="text-sm opacity-60">
          No interactions with this client yet.
        </div>
      <% else %>
        <div class="card border border-dashed border-base-300 bg-base-100">
          <div class="card-body items-center text-center py-8 gap-2">
            <p class="text-sm opacity-70">
              No client linked to this project yet.
            </p>
            <p class="text-xs opacity-50">
              Set the company UUID in the project's Modules & features panel
              (find it on the company page in
              <.link navigate={Paths.companies()} class="link">CRM › Companies</.link>).
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp ngettext_members(1), do: "1 member contact"
  defp ngettext_members(n), do: "#{n} member contacts"

  defp maybe_put_locale(%{"locale" => locale}) when is_binary(locale) and locale != "" do
    Gettext.put_locale(PhoenixKitCRM.Gettext, locale)
  rescue
    _ -> :ok
  end

  defp maybe_put_locale(_), do: :ok

  # A CRM DB hiccup degrades the tab to its empty state — a contributed
  # extension tab must never crash the host project page.
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
