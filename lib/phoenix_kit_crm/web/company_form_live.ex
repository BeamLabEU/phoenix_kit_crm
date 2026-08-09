defmodule PhoenixKitCRM.Web.CompanyFormLive do
  @moduledoc "New / edit form for a CRM company."
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  import PhoenixKitCRM.Web.PartyRoleHelpers,
    only: [active_role_values: 1, role_label: 1, selected_roles: 1, sync_roles: 3]

  alias PhoenixKitCRM.{Activity, Companies, Paths}
  alias PhoenixKitCRM.Schemas.{Company, PartyRole}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        company = %Company{}
        {:noreply, assign_form(socket, company, gettext("New company"))}

      :edit ->
        case Companies.get_company(params["uuid"]) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Company not found"))
             |> push_navigate(to: Paths.companies())}

          company ->
            {:noreply, assign_form(socket, company, gettext("Edit company"))}
        end
    end
  end

  defp assign_form(socket, company, title) do
    roles_selected = if company.uuid, do: active_role_values(company), else: []

    socket
    |> assign(:company, company)
    |> assign(:page_title, title)
    |> assign(:page_section, gettext("Companies"))
    |> assign(:page_section_path, Paths.companies())
    |> assign(:roles_selected, roles_selected)
    |> assign(:form, to_form(Companies.change_company(company)))
  end

  @impl true
  def handle_event("validate", %{"company" => params} = payload, socket) do
    changeset =
      socket.assigns.company
      |> Companies.change_company(safe_map(params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:roles_selected, selected_roles(payload))
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("save", %{"company" => params} = payload, socket) do
    # Normalize once so a forged non-map payload can't raise here OR in the rescue.
    params = safe_map(params)
    socket = assign(socket, :roles_selected, selected_roles(payload))
    save(socket, socket.assigns.live_action, params)
  rescue
    e ->
      Logger.error(
        "[CRM] company save crashed (company_uuid=#{inspect(socket.assigns.company.uuid)}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      # Rebuild @form from the submitted params so the rerender shows what the
      # user typed (not stale values from the last phx-change).
      changeset =
        socket.assigns.company |> Companies.change_company(params) |> Map.put(:action, :validate)

      {:noreply,
       socket
       |> put_flash(
         :error,
         gettext(
           "Something went wrong saving this company. Your input was kept — please try again."
         )
       )
       |> assign(:form, to_form(changeset))}
  end

  # Ignore unexpected/forged events (and malformed validate/save payloads).
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save(socket, :new, params) do
    case Companies.create_company(params) do
      {:ok, company} ->
        roles = sync_roles(company, socket.assigns.roles_selected, Activity.actor_uuid(socket))

        Activity.log(
          "crm.company_created",
          Activity.actor_opts(socket) ++
            [resource_type: "crm_company", resource_uuid: company.uuid]
        )

        finish_save(socket, company, roles, gettext("Company created"))

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Companies.update_company(socket.assigns.company, params) do
      {:ok, company} ->
        roles = sync_roles(company, socket.assigns.roles_selected, Activity.actor_uuid(socket))

        Activity.log(
          "crm.company_updated",
          Activity.actor_opts(socket) ++
            [resource_type: "crm_company", resource_uuid: company.uuid]
        )

        finish_save(socket, company, roles, gettext("Company updated"))

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # Roles fully reconciled → flash success and leave.
  defp finish_save(socket, company, :ok, msg) do
    {:noreply,
     socket
     |> put_flash(:info, msg)
     |> push_navigate(to: Paths.company(company.uuid))}
  end

  # A role grant/revoke failed → the company IS saved, but stay on the form
  # (now editing it) with a warning so the unapplied role isn't lost silently.
  defp finish_save(socket, company, {:partial, _failed}, _msg) do
    {:noreply,
     socket
     |> put_flash(
       :warning,
       gettext(
         "Company saved, but some commercial roles couldn't be applied — please re-check and save."
       )
     )
     |> assign(:company, company)
     |> assign(:live_action, :edit)
     |> assign(:page_title, gettext("Edit company"))
     |> assign(:roles_selected, active_role_values(company))
     |> assign(:form, to_form(Companies.change_company(company)))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex-col mx-auto px-4 py-6 max-w-2xl">
      <.form for={@form} phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body flex flex-col gap-5">
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.select field={@form[:status]} label={gettext("Status")} options={status_options()} />
            <.input field={@form[:website]} label={gettext("Website")} />
            <.input field={@form[:email]} type="email" label={gettext("Email")} />
            <.input field={@form[:phone]} label={gettext("Phone")} />
            <.input field={@form[:industry]} label={gettext("Industry")} />
            <.textarea field={@form[:address]} label={gettext("Address")} />
            <.textarea field={@form[:notes]} label={gettext("Notes")} />

            <div class="divider my-1 text-sm font-semibold text-base-content/60">
              {gettext("Commercial roles")}
            </div>
            <div class="flex flex-wrap gap-4">
              <label :for={role <- PartyRole.roles()} class="label cursor-pointer gap-2">
                <input
                  type="checkbox"
                  name="roles[]"
                  value={role}
                  checked={role in @roles_selected}
                  class="checkbox checkbox-sm"
                />
                <span class="label-text">{role_label(role)}</span>
              </label>
            </div>

            <div class="divider my-0"></div>
            <div class="flex justify-end gap-2">
              <.link navigate={Paths.companies()} class="btn btn-ghost">{gettext("Cancel")}</.link>
              <.button type="submit" class="btn-primary" phx-disable-with={gettext("Saving…")}>
                {gettext("Save")}
              </.button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp status_options, do: Enum.map(Company.statuses(), &{status_label(&1), &1})

  defp status_label("active"), do: gettext("Active")
  defp status_label("inactive"), do: gettext("Inactive")
  defp status_label(s), do: s

  defp safe_map(p) when is_map(p), do: p
  defp safe_map(_), do: %{}
end
