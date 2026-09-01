defmodule PhoenixKitCRM.Web.ProjectClientLive do
  @moduledoc """
  The CRM **Client** tab for the `phoenix_kit_projects` hub — this module's
  `phoenix_kit_project_extensions/0` contribution (see that function in
  `PhoenixKitCRM`).

  Rendered by the projects hub via `live_render` with the hub's
  embed-session contract: `"project_uuid"` (the host project),
  `"config"` (this instance's config — `company_uuid` links the client),
  `"current_user_uuid"` / `"locale"`. Linkage is CONFIG-based — no FK, no
  dependency on the projects package; the admin picks the company in the
  project's Modules & features panel (a select over
  `PhoenixKitCRM.Companies.company_options/0`).

  Shows the linked company card, its member contacts, and the most recent
  interactions with the client — the company's own (company-anchored, V05)
  merged with its members' — with link-outs to the CRM admin. Read-only here — mutations live in CRM. The
  extension declares no write action, so the hub hands this tab
  `"can_write" => false` and there is nothing to gate.

  Off-router-mountable: no `handle_params/3` (the hub's hard requirement),
  so CRM reads run on the connected mount only — the hub renders the
  landing tab in the project page's dead render too, and an unguarded
  mount would run every query twice.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  alias PhoenixKitCRM.{Companies, Interactions, Paths}
  alias PhoenixKitCRM.Schemas.{Company, Interaction}

  @recent_limit 5

  @impl true
  def mount(_params, session, socket) do
    maybe_put_locale(session)

    socket =
      assign(socket,
        project_uuid: session["project_uuid"],
        company_uuid: config_company_uuid(session),
        company: nil,
        memberships: [],
        recent: [],
        loading: true
      )

    {:ok, if(connected?(socket), do: load(socket), else: socket)}
  end

  defp config_company_uuid(session) do
    case get_in(session, ["config", "company_uuid"]) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  defp load(%{assigns: %{company_uuid: nil}} = socket), do: assign(socket, loading: false)

  defp load(socket) do
    company = safe(fn -> Companies.get_company(socket.assigns.company_uuid) end)

    {memberships, recent} =
      if company do
        memberships = safe(fn -> Companies.list_memberships(company.uuid) end) || []

        # Limit in the QUERY: this tab shows the newest few. "Recent
        # interactions with this client" means the company's OWN
        # (company-anchored, V05) merged with its members' — list_for_company
        # limits the combined window in SQL.
        recent =
          safe(fn -> Interactions.list_for_company(company.uuid, limit: @recent_limit) end) ||
            []

        {memberships, recent}
      else
        {[], []}
      end

    assign(socket, company: company, memberships: memberships, recent: recent, loading: false)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= cond do %>
        <% @loading -> %>
          <div class="card border border-base-200 bg-base-100">
            <div class="card-body py-4">
              <div class="flex items-center gap-3">
                <div class="skeleton w-10 h-10 rounded-full shrink-0"></div>
                <div class="flex flex-col gap-2 grow">
                  <div class="skeleton h-4 w-40"></div>
                  <div class="skeleton h-3 w-24"></div>
                </div>
              </div>
            </div>
          </div>
        <% @company -> %>
          <div class="card border border-base-200 bg-base-100">
            <div class="card-body py-4 gap-2">
              <div class="flex items-center gap-3">
                <div class="avatar placeholder">
                  <div class="bg-primary/10 text-primary rounded-full w-10 h-10">
                    <span class="text-sm font-bold">{initial(@company.name)}</span>
                  </div>
                </div>
                <div class="min-w-0 grow">
                  <div class="flex items-center gap-2 min-w-0">
                    <h3 class="font-semibold truncate">{@company.name}</h3>
                    <%!-- The linkage is config-based, so trashing the company in
                         CRM can't unlink it here — say so instead of presenting a
                         soft-deleted company as the live client. --%>
                    <span :if={Company.trashed?(@company)} class="badge badge-warning badge-sm shrink-0">
                      {gettext("Trashed")}
                    </span>
                  </div>
                  <p class="text-xs opacity-60">
                    {ngettext("%{count} member contact", "%{count} member contacts", length(@memberships))}
                  </p>
                </div>
                <.link navigate={Paths.company(@company.uuid)} class="btn btn-ghost btn-sm gap-1">
                  <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                  {gettext("Open in CRM")}
                </.link>
              </div>
            </div>
          </div>

          <div :if={@recent != []} class="card border border-base-200 bg-base-100">
            <div class="card-body py-4 gap-2">
              <h4 class="text-sm font-semibold opacity-70">{gettext("Recent interactions")}</h4>
              <div class="divide-y divide-base-200">
                <div :for={interaction <- @recent} class="py-2 flex items-baseline gap-2 text-sm">
                  <span class="badge badge-ghost badge-xs shrink-0">
                    {Interaction.type_label(interaction.interaction_type)}
                  </span>
                  <span class="truncate min-w-0">
                    {interaction.subject || gettext("(no subject)")}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <div :if={@recent == []} class="text-sm opacity-60">
            {gettext("No interactions with this client yet.")}
          </div>
        <% true -> %>
          <div class="card border border-dashed border-base-300 bg-base-100">
            <div class="card-body items-center text-center py-8 gap-2">
              <p class="text-sm opacity-70">
                {gettext("No client linked to this project yet.")}
              </p>
              <p class="text-xs opacity-50">
                {gettext("Pick the client company in the project's Modules & features panel.")}
              </p>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp initial(name) when is_binary(name) do
    case String.first(String.trim(name)) do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end

  defp initial(_), do: "?"

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
