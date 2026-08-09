defmodule PhoenixKitCRM.Web.ContactFormLive do
  @moduledoc """
  New / edit form for a CRM contact: the profile fields, a single company
  block (company + free-form role + department), and the optional
  "allow login" checkbox (staff-style find-or-create user link).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  import PhoenixKitCRM.Web.PartyRoleHelpers,
    only: [active_role_values: 1, role_label: 1, selected_roles: 1, sync_roles: 3]

  alias PhoenixKitCRM.{Activity, Companies, Contacts, Paths}
  alias PhoenixKitCRM.Schemas.{Contact, PartyRole}

  @impl true
  def mount(_params, _session, socket) do
    # No DB queries in mount/3 — it runs twice (HTTP + WebSocket). The company
    # list loads in handle_params via the form assigners below.
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply, assign_new_form(socket)}

      :edit ->
        case Contacts.get_contact(params["uuid"]) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("Contact not found"))
             |> push_navigate(to: Paths.contacts())}

          contact ->
            {:noreply, assign_edit_form(socket, contact)}
        end
    end
  end

  defp assign_new_form(socket) do
    socket
    |> assign(:companies, Companies.list_companies())
    |> assign(:contact, %Contact{})
    |> assign(:page_title, gettext("New contact"))
    |> assign(:page_section, gettext("Contacts"))
    |> assign(:page_section_path, Paths.contacts())
    |> assign(:form, to_form(Contacts.change_contact(%Contact{})))
    |> assign(:company_uuid, nil)
    |> assign(:role_in_company, "")
    |> assign(:department, "")
    |> assign(:roles_selected, [])
    |> assign(:allow_login, false)
  end

  defp assign_edit_form(socket, contact) do
    membership = Contacts.primary_membership(contact)

    socket
    |> assign(:companies, Companies.list_companies())
    |> assign(:contact, contact)
    |> assign(:page_title, gettext("Edit contact"))
    |> assign(:page_section, gettext("Contacts"))
    |> assign(:page_section_path, Paths.contacts())
    |> assign(:form, to_form(Contacts.change_contact(contact)))
    |> assign(:company_uuid, membership && membership.company_uuid)
    |> assign(:role_in_company, (membership && membership.role_in_company) || "")
    |> assign(:department, (membership && membership.department) || "")
    |> assign(:roles_selected, active_role_values(contact))
    |> assign(:allow_login, not is_nil(contact.user_uuid))
  end

  @impl true
  def handle_event("validate", params, socket) do
    contact_params = safe_map(params["contact"])

    changeset =
      socket.assigns.contact
      |> Contacts.change_contact(contact_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:company_uuid, blank_to_nil(params["company_uuid"]))
     |> assign(:role_in_company, safe_text(params["role_in_company"]))
     |> assign(:department, safe_text(params["department"]))
     |> assign(:roles_selected, selected_roles(params))
     |> assign(:allow_login, params["allow_login"] == "true")}
  end

  def handle_event("save", params, socket) do
    socket = assign(socket, :roles_selected, selected_roles(params))
    contact_params = safe_map(params["contact"])
    company_uuid = blank_to_nil(params["company_uuid"])
    role = safe_text(params["role_in_company"])
    dept = safe_text(params["department"])
    allow_login = params["allow_login"] == "true"
    email = contact_params["email"]

    if allow_login and blank?(email) do
      changeset =
        socket.assigns.contact
        |> Contacts.change_contact(contact_params)
        |> Ecto.Changeset.add_error(:email, gettext("is required to enable login"))
        |> Map.put(:action, :validate)

      {:noreply, restore_form(socket, changeset, company_uuid, role, dept, true)}
    else
      do_save(
        socket,
        socket.assigns.live_action,
        contact_params,
        company_uuid,
        role,
        dept,
        allow_login,
        email
      )
    end
  end

  # Ignore any unexpected/forged event rather than crashing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp do_save(socket, action, contact_params, company_uuid, role, dept, allow_login, email) do
    result =
      case action do
        :new -> Contacts.create_contact(contact_params)
        :edit -> Contacts.update_contact(socket.assigns.contact, contact_params)
      end

    case result do
      {:ok, contact} ->
        # All three are best-effort secondary ops (each logs + swallows its own
        # failure). roles returns :ok | {:partial, _}; membership/login :ok | :error.
        roles = sync_roles(contact, socket.assigns.roles_selected, actor_uuid(socket))
        membership = apply_membership(contact, company_uuid, role, dept)
        login = apply_login(contact, allow_login, email, actor_uuid(socket))

        Activity.log(
          "crm.contact_#{verb(action)}",
          Activity.actor_opts(socket) ++
            [resource_type: "crm_contact", resource_uuid: contact.uuid]
        )

        if membership == :ok and login == :ok and roles == :ok do
          {:noreply,
           socket
           |> put_flash(:info, gettext("Contact saved"))
           |> push_navigate(to: Paths.contact(contact.uuid))}
        else
          # A requested secondary op failed. STAY on the form (now editing the
          # just-saved contact) so the typed company/role/dept/login aren't lost —
          # re-saving updates, it won't create a duplicate.
          {:noreply,
           socket
           |> put_flash(
             :warning,
             gettext(
               "Contact saved, but the company link, login, or roles couldn't all be applied — please re-check and save."
             )
           )
           |> assign(:contact, contact)
           |> assign(:live_action, :edit)
           |> assign(:page_title, gettext("Edit contact"))
           |> assign(:roles_selected, active_role_values(contact))
           |> restore_form(
             Contacts.change_contact(contact),
             company_uuid,
             role,
             dept,
             allow_login
           )}
        end

      {:error, changeset} ->
        {:noreply, restore_form(socket, changeset, company_uuid, role, dept, allow_login)}
    end
  rescue
    e ->
      Logger.error(
        "[CRM] contact save crashed (contact_uuid=#{inspect(socket.assigns.contact.uuid)}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      changeset =
        socket.assigns.contact
        |> Contacts.change_contact(contact_params)
        |> Map.put(:action, :validate)

      {:noreply,
       socket
       |> put_flash(
         :error,
         gettext(
           "Something went wrong saving this contact. Your input was kept — please try again."
         )
       )
       |> restore_form(changeset, company_uuid, role, dept, allow_login)}
  end

  # Re-assign the changeset AND the side fields (company/role/dept/login) so a
  # validation error never wipes what the user typed in those non-`@form` fields.
  defp restore_form(socket, changeset, company_uuid, role, dept, allow_login) do
    socket
    |> assign(:form, to_form(changeset))
    |> assign(:company_uuid, company_uuid)
    # role/dept always arrive as strings (built via safe_text/1 at the call sites).
    |> assign(:role_in_company, role)
    |> assign(:department, dept)
    |> assign(:allow_login, allow_login)
  end

  # Each returns :ok | :error (logged) — they reconcile secondary state and must
  # never raise out to do_save (which would convert a saved contact into a crash).
  defp apply_membership(contact, company_uuid, role, dept) do
    case Contacts.set_primary_company(contact, company_uuid, role, dept) do
      {:ok, _} ->
        :ok

      {:error, cs} ->
        Logger.warning("[CRM] set_primary_company failed: #{inspect(cs.errors)}")
        :error
    end
  rescue
    e ->
      Logger.warning(
        "[CRM] set_primary_company raised: " <> Exception.format(:error, e, __STACKTRACE__)
      )

      :error
  end

  defp apply_login(contact, true, email, actor_uuid) do
    was_connected? = not is_nil(contact.user_uuid)

    case Contacts.connect_user(contact, email) do
      {:ok, _linked, _status} ->
        # Log only a genuine state change, not every re-save of an already-linked
        # contact.
        unless was_connected?, do: log_login("crm.contact_login_connected", contact, actor_uuid)
        :ok

      other ->
        Logger.warning("[CRM] connect_user failed: #{inspect(other)}")
        :error
    end
  rescue
    e ->
      Logger.warning("[CRM] connect_user raised: " <> Exception.format(:error, e, __STACKTRACE__))
      :error
  end

  defp apply_login(%{user_uuid: nil}, false, _email, _actor_uuid), do: :ok

  defp apply_login(contact, false, _email, actor_uuid) do
    case Contacts.disconnect_user(contact) do
      {:ok, _unlinked} ->
        log_login("crm.contact_login_disconnected", contact, actor_uuid)
        :ok

      other ->
        Logger.warning("[CRM] disconnect_user failed: #{inspect(other)}")
        :error
    end
  rescue
    e ->
      Logger.warning(
        "[CRM] disconnect_user raised: " <> Exception.format(:error, e, __STACKTRACE__)
      )

      :error
  end

  defp log_login(action, contact, actor_uuid) do
    Activity.log(action,
      actor_uuid: actor_uuid,
      resource_type: "crm_contact",
      resource_uuid: contact.uuid
    )
  end

  defp verb(:new), do: "created"
  defp verb(:edit), do: "updated"

  defp actor_uuid(socket), do: Keyword.get(Activity.actor_opts(socket), :actor_uuid)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex-col mx-auto px-4 py-6 max-w-2xl">
      <.form for={@form} phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body flex flex-col gap-5">
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.input field={@form[:email]} type="email" label={gettext("Email")} />
            <.input field={@form[:phone]} label={gettext("Phone")} />
            <.select field={@form[:status]} label={gettext("Status")} options={status_options()} />

            <div>
              <.input field={@form[:locale]} label={gettext("Locale")} placeholder="en / de-DE" />
              <p class="text-xs text-base-content/50 mt-1">
                {gettext(
                  "Language/region code used to pick this contact's language when sending (e.g. \"en\", \"de-DE\")."
                )}
              </p>
            </div>

            <.textarea field={@form[:notes]} label={gettext("Notes")} />

            <div class="divider my-1 text-sm font-semibold text-base-content/60">
              {gettext("Company")}
            </div>

            <div>
              <.select
                id="contact-company"
                name="company_uuid"
                value={@company_uuid}
                label={gettext("Company")}
                prompt={gettext("— none —")}
                options={Enum.map(@companies, &{&1.name, &1.uuid})}
              />
              <p class="text-xs text-base-content/50 mt-1">
                {gettext("Pick an existing company, or")}
                <.link navigate={Paths.company_new()} class="link">{gettext("create one")}</.link>.
              </p>
            </div>

            <.input id="contact-role" name="role_in_company" value={@role_in_company} label={gettext("Role in company")} />
            <.input id="contact-department" name="department" value={@department} label={gettext("Department / team")} />

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

            <div class="divider my-1 text-sm font-semibold text-base-content/60">
              {gettext("Login")}
            </div>

            <.checkbox
              name="allow_login"
              checked={@allow_login}
              label={gettext("Allow this person to log in")}
            >
              {gettext("Connects the contact to a user account (creates one if none exists for the email). Requires an email. They set a password via the normal sign-in flow.")}
            </.checkbox>

            <div class="divider my-0"></div>
            <div class="flex justify-end gap-2">
              <.link navigate={Paths.contacts()} class="btn btn-ghost">{gettext("Cancel")}</.link>
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

  defp status_options, do: Enum.map(Contact.statuses(), &{status_label(&1), &1})

  defp status_label("active"), do: gettext("Active")
  defp status_label("inactive"), do: gettext("Inactive")
  defp status_label(s), do: s
  defp blank?(v), do: is_nil(v) or (is_binary(v) and String.trim(v) == "")

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(_), do: nil

  # Forged/malformed payloads can send non-map "contact" or non-string side
  # fields — normalize before they reach a changeset (which would raise).
  defp safe_map(p) when is_map(p), do: p
  defp safe_map(_), do: %{}
  defp safe_text(s) when is_binary(s), do: s
  defp safe_text(_), do: ""
end
