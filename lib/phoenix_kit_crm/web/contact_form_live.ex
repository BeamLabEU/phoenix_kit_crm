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

  import PhoenixKitCRM.Web.Components.MirrorPanel, only: [mirror_panel: 1]
  import PhoenixKitCRM.Web.Components.MirrorConflictModal, only: [mirror_conflict_modal: 1]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{Activity, Companies, Contacts, Mirror, Paths}
  alias PhoenixKitCRM.Schemas.{Contact, PartyRole}

  # Whitelist for the conflict-resolution form's per-field radios — never
  # `String.to_atom/1` (atom-exhaustion) or `String.to_existing_atom/1`
  # (crashes the LiveView on a crafted key) a submitted param directly.
  @resolvable_fields %{"name" => :name, "email" => :email}

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
        {:noreply, assign_new_form(socket, params)}

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

  # `?company_uuid=` is how a company page adds a member: the form opens
  # with that company preselected. Only a company from the list is
  # honoured — a stale or forged uuid leaves the field empty.
  defp assign_new_form(socket, params) do
    companies = Companies.list_companies()

    preselected =
      case params["company_uuid"] do
        uuid when is_binary(uuid) -> Enum.find_value(companies, &(&1.uuid == uuid and uuid))
        _ -> nil
      end

    socket
    |> assign(:companies, companies)
    |> assign(:contact, %Contact{})
    |> assign(:page_title, gettext("New contact"))
    |> assign(:page_section, gettext("Contacts"))
    |> assign(:page_section_path, Paths.contacts())
    |> assign(:form, to_form(Contacts.change_contact(%Contact{})))
    |> assign(:company_uuid, preselected)
    |> assign(:role_in_company, "")
    |> assign(:department, "")
    |> assign(:roles_selected, [])
    |> assign(:allow_login, false)
    |> assign_mirror_defaults(nil, nil)
  end

  defp assign_edit_form(socket, contact) do
    membership = Contacts.primary_membership(contact)
    linked_user = linked_user_for(contact)

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
    |> assign_mirror_defaults(
      linked_user,
      linked_user && Paths.user_view(linked_user.uuid)
    )
  end

  defp assign_mirror_defaults(socket, linked_user, linked_account_path) do
    socket
    |> assign(:linked_user, linked_user)
    |> assign(:linked_account_path, linked_account_path)
    |> assign(:mirror_conflicts, [])
    |> assign(:mirror_choices, %{})
    |> assign(:show_conflict, false)
    |> assign(:mirror_pending_user_uuid, nil)
    |> assign(:show_picker, false)
    |> assign(:picker_candidates, [])
  end

  defp linked_user_for(%Contact{user_uuid: nil}), do: nil
  defp linked_user_for(%Contact{user_uuid: uuid}), do: Auth.get_user(uuid)

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

  # ── Mirror account (person-user link) ─────────────────────────────────
  #
  # ADDITIVE to the existing allow_login checkbox/apply_login (Q2: both
  # stay). Only reachable once the contact is persisted (the panel itself
  # isn't rendered before then — see render/1), so
  # `socket.assigns.contact.uuid` is always set in every handler below.

  def handle_event("mirror_create", _params, socket) do
    case Contacts.create_mirror_user(socket.assigns.contact) do
      {:ok, {contact, user}} ->
        {:noreply,
         socket
         |> assign(:contact, contact)
         |> assign(:linked_user, user)
         |> assign(:linked_account_path, Paths.user_view(user.uuid))
         |> put_flash(:info, gettext("Mirror account created and linked"))}

      {:error, :already_linked} ->
        {:noreply,
         put_flash(socket, :error, gettext("This contact already has a mirror account"))}

      {:error, other} ->
        Logger.warning("[CRM] create_mirror_user failed: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, gettext("Could not create a mirror account"))}
    end
  end

  def handle_event("mirror_open_picker", _params, socket) do
    linked = Contacts.linked_user_uuids()
    %{users: persons} = Auth.list_users_paginated(account_type: "person", page_size: 500)
    candidates = Enum.reject(persons, &MapSet.member?(linked, &1.uuid))

    {:noreply,
     socket
     |> assign(:show_picker, true)
     |> assign(:picker_candidates, candidates)}
  end

  def handle_event("mirror_close_picker", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_picker, false)
     |> assign(:picker_candidates, [])}
  end

  def handle_event("mirror_link", %{"user_uuid" => user_uuid}, socket) do
    contact = socket.assigns.contact

    case Auth.get_user(user_uuid) do
      %User{account_type: "person"} = user ->
        # Re-check even though link_user/2 also guards — the diff/fill
        # path below writes to `user` directly and must not run against a
        # type link_user would reject anyway.
        case Mirror.diff(contact, user) do
          [] ->
            link_without_conflict(socket, contact, user)

          conflicts ->
            {:noreply,
             socket
             |> assign(:mirror_conflicts, conflicts)
             |> assign(:mirror_choices, %{})
             |> assign(:mirror_pending_user_uuid, user_uuid)
             |> assign(:show_conflict, true)
             |> assign(:show_picker, false)
             |> assign(:picker_candidates, [])}
        end

      %User{} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only person accounts can mirror a contact"))}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("That account no longer exists"))}
    end
  end

  # Keeps the modal's radio selections in server assigns (@mirror_choices)
  # rather than trusting the DOM — see MirrorConflictModal's moduledoc for
  # why an uncontrolled radio is a real bug here. Filtered against
  # @mirror_conflicts (the modal-open-time diff — cheap, no DB hit; the
  # DB-backed re-check happens at resolve time, below).
  def handle_event("mirror_choice_changed", %{"choices" => raw_choices}, socket) do
    allowed = allowed_conflict_fields(socket.assigns.mirror_conflicts)
    updates = atomize_choices(raw_choices, allowed)

    {:noreply, update(socket, :mirror_choices, &Map.merge(&1, updates))}
  end

  def handle_event("mirror_choice_changed", _params, socket), do: {:noreply, socket}

  def handle_event("mirror_resolve", %{"choices" => raw_choices}, socket) do
    # Re-fetch BOTH sides fresh rather than trusting socket.assigns.contact
    # or the cached @mirror_conflicts — either record may have changed
    # while the modal sat open. Mirror.resolve/4 also re-checks divergence
    # per field internally (the Task C hardening guard), so this is
    # belt-and-suspenders, not redundant with nothing.
    contact = Contacts.get_contact(socket.assigns.contact.uuid)
    user = Auth.get_user(socket.assigns.mirror_pending_user_uuid)

    case {contact, user} do
      {%Contact{}, %User{}} ->
        fresh_conflicts = Mirror.diff(contact, user)
        choices = atomize_choices(raw_choices, allowed_conflict_fields(fresh_conflicts))
        deltas = Mirror.resolve(:contact, contact, user, choices)

        case Contacts.apply_mirror_resolution(contact, user, deltas) do
          {:ok, {linked_contact, linked_user}} ->
            {:noreply,
             socket
             |> assign(:contact, linked_contact)
             |> assign_form_after_resolution(linked_contact, deltas.crm)
             |> assign(:linked_user, linked_user)
             |> assign(:linked_account_path, Paths.user_view(linked_user.uuid))
             |> close_conflict()
             |> put_flash(:info, gettext("Mirror account linked"))}

          {:error, other} ->
            Logger.warning(
              "[CRM] mirror_resolve failed (contact=#{inspect(contact.uuid)}): #{inspect(other)}"
            )

            {:noreply,
             socket
             |> close_conflict()
             |> put_flash(:error, gettext("Could not apply the resolution — please try again"))}
        end

      _ ->
        Logger.warning(
          "[CRM] mirror_resolve: contact or user missing (contact_uuid=#{inspect(socket.assigns.contact.uuid)}, " <>
            "user_uuid=#{inspect(socket.assigns.mirror_pending_user_uuid)})"
        )

        {:noreply,
         socket
         |> close_conflict()
         |> put_flash(:error, gettext("Could not apply the resolution — please try again"))}
    end
  end

  def handle_event("mirror_cancel_conflict", _params, socket) do
    {:noreply, close_conflict(socket)}
  end

  # The resolution just wrote the contact, but the inputs on screen still
  # carry the values from before it — and Save is the next click, which
  # would write those stale values straight back and silently undo the
  # resolution. Rebuild the form from the resolved record for the fields
  # the resolution wrote; keep the operator's unsaved draft for every other
  # field, so an edit typed before the modal opened is not thrown away.

  def handle_event("mirror_unlink", _params, socket) do
    case Contacts.disconnect_user(socket.assigns.contact) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> assign(:contact, contact)
         |> assign(:linked_user, nil)
         |> assign(:linked_account_path, nil)
         |> put_flash(:info, gettext("Mirror account unlinked"))}

      {:error, other} ->
        Logger.warning("[CRM] disconnect_user failed: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, gettext("Could not unlink the mirror account"))}
    end
  end

  # Ignore any unexpected/forged event rather than crashing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp link_without_conflict(socket, contact, user) do
    case Contacts.link_user(contact, user.uuid) do
      {:ok, linked_contact} ->
        linked_user = fill_blank_user_fields(user, contact)

        {:noreply,
         socket
         |> assign(:contact, linked_contact)
         |> assign(:linked_user, linked_user)
         |> assign(:linked_account_path, Paths.user_view(linked_user.uuid))
         |> assign(:show_picker, false)
         |> assign(:picker_candidates, [])
         |> put_flash(:info, gettext("Linked to mirror account"))}

      {:error, other} ->
        Logger.warning("[CRM] link_user failed: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, gettext("Could not link this account"))}
    end
  end

  # Best-effort secondary write (mirrors apply_membership/apply_login just
  # above) — only fills fields the user side is currently BLANK on; a
  # matching non-blank value is never touched. A failure here doesn't undo
  # the link, only logs.
  defp fill_blank_user_fields(user, contact) do
    attrs =
      :contact
      |> Mirror.attrs_from(contact)
      |> Map.take([:first_name, :last_name, :email])
      |> Enum.filter(fn {field, value} -> not is_nil(value) and blank?(Map.get(user, field)) end)
      |> Map.new()

    if attrs == %{} do
      user
    else
      case Auth.update_user_profile(user, attrs) do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          Logger.warning("[CRM] fill_blank_user_fields failed: #{inspect(changeset.errors)}")
          user
      end
    end
  end

  defp assign_form_after_resolution(socket, contact, crm_deltas) do
    # Browser params are string-keyed; a caller handing in atom keys gets
    # the same treatment rather than a stale value slipping through.
    resolved = Map.keys(crm_deltas)

    draft =
      Map.drop(socket.assigns.form.params || %{}, resolved ++ Enum.map(resolved, &to_string/1))

    assign(socket, :form, to_form(Contacts.change_contact(contact, draft)))
  end

  defp close_conflict(socket) do
    socket
    |> assign(:mirror_conflicts, [])
    |> assign(:mirror_choices, %{})
    |> assign(:show_conflict, false)
    |> assign(:mirror_pending_user_uuid, nil)
  end

  defp allowed_conflict_fields(conflicts), do: conflicts |> Enum.map(& &1.field) |> MapSet.new()

  # Whitelisted conversion — see @resolvable_fields above for the safety
  # rationale. Doubly filtered: the field name must be one of the two
  # fields this kind ever mirrors AND must be in `allowed_fields` (the
  # fields actually diverging right now). Unknown field names,
  # non-diverging fields, and unrecognized choice values are all silently
  # dropped rather than raising on a forged payload.
  defp atomize_choices(raw_choices, allowed_fields) when is_map(raw_choices) do
    for {field, value} <- raw_choices,
        atom_field = Map.get(@resolvable_fields, field),
        not is_nil(atom_field),
        MapSet.member?(allowed_fields, atom_field),
        side = choice_side(value),
        not is_nil(side),
        into: %{} do
      {atom_field, side}
    end
  end

  defp atomize_choices(_, _), do: %{}

  defp choice_side("keep_crm"), do: :crm
  defp choice_side("keep_user"), do: :user
  defp choice_side(_), do: nil

  defp picker_label(%User{first_name: first, last_name: last, email: email}) do
    case String.trim("#{first} #{last}") do
      "" -> email
      personal -> "#{personal} — #{email}"
    end
  end

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
          linked_user = linked_user_for(contact)

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
           |> assign(:linked_user, linked_user)
           |> assign(:linked_account_path, linked_user && Paths.user_view(linked_user.uuid))
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
                <span class="fieldset-legend">{role_label(role)}</span>
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

      <%!--
        A separate card, not inside the form above: this panel and its picker
        fire their own phx-submit ("mirror_link"), and HTML doesn't allow a
        <form> nested inside another <form> — the contact save form above
        must stay self-contained. Additive to the allow_login checkbox above
        (owner Q2: both stay).
      --%>
      <div :if={@contact.uuid} class="card bg-base-100 shadow-sm mt-4">
        <div class="card-body flex flex-col gap-3">
          <div class="text-sm font-semibold text-base-content/60">{gettext("Mirror account")}</div>

          <.mirror_panel
            kind={:contact}
            linked_user={@linked_user}
            can_link={true}
            account_path={@linked_account_path}
          />

          <.form
            :if={@show_picker}
            for={%{}}
            id="mirror-picker-form"
            phx-submit="mirror_link"
            class="space-y-2"
          >
            <.select
              id="mirror-picker-select"
              name="user_uuid"
              value={nil}
              prompt={gettext("— choose an account —")}
              options={Enum.map(@picker_candidates, &{picker_label(&1), &1.uuid})}
            />
            <div class="flex gap-2">
              <.button type="submit" variant="primary" size="xs">{gettext("Link")}</.button>
              <.button type="button" phx-click="mirror_close_picker" variant="ghost" size="xs">
                {gettext("Cancel")}
              </.button>
            </div>
          </.form>
        </div>
      </div>

      <p :if={!@contact.uuid} class="mt-4 text-xs text-base-content/50">
        {gettext("Save the contact first to link or create a mirror account.")}
      </p>
    </div>

    <.mirror_conflict_modal
      conflicts={@mirror_conflicts}
      master={:crm}
      choices={@mirror_choices}
      show={@show_conflict}
    />
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
