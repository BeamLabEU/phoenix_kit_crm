defmodule PhoenixKitCRM.Web.CompanyFormLive do
  @moduledoc "New / edit form for a CRM company."
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  import PhoenixKitCRM.Web.PartyRoleHelpers,
    only: [active_role_values: 1, role_label: 1, selected_roles: 1, sync_roles: 3]

  import PhoenixKitCRM.Web.Components.MirrorPanel, only: [mirror_panel: 1]
  import PhoenixKitCRM.Web.Components.MirrorConflictModal, only: [mirror_conflict_modal: 1]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{Activity, Companies, Mirror, Paths}
  alias PhoenixKitCRM.Schemas.{Company, PartyRole}

  # Whitelist for the conflict-resolution form's per-field radios — never
  # `String.to_existing_atom/1` a submitted param directly (same discipline
  # core's own reorder_modal strategy picker uses for its `strategy` param).
  @resolvable_fields %{"name" => :name, "email" => :email}

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
    linked_user = linked_user_for(company)

    socket
    |> assign(:company, company)
    |> assign(:page_title, title)
    |> assign(:page_section, gettext("Companies"))
    |> assign(:page_section_path, Paths.companies())
    |> assign(:roles_selected, roles_selected)
    |> assign(:form, to_form(Companies.change_company(company)))
    |> assign(
      :org_accounts_enabled,
      Settings.get_boolean_setting("enable_organization_accounts", false)
    )
    |> assign(:linked_user, linked_user)
    |> assign(:linked_account_path, linked_user && Paths.user_view(linked_user.uuid))
    |> assign(:mirror_conflicts, [])
    |> assign(:mirror_choices, %{})
    |> assign(:show_conflict, false)
    |> assign(:mirror_pending_user_uuid, nil)
    |> assign(:show_picker, false)
    |> assign(:picker_candidates, [])
  end

  defp linked_user_for(%Company{user_uuid: nil}), do: nil
  defp linked_user_for(%Company{user_uuid: uuid}), do: Auth.get_user(uuid)

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

  # ── Mirror account (organization-user link) ──────────────────────────
  #
  # Only reachable once the company is persisted (the panel itself isn't
  # rendered before then — see render/1), so `socket.assigns.company.uuid`
  # is always set in every handler below.

  def handle_event("mirror_create", _params, socket) do
    if socket.assigns.org_accounts_enabled do
      case Companies.create_mirror_user(socket.assigns.company) do
        {:ok, {company, user}} ->
          {:noreply,
           socket
           |> assign(:company, company)
           |> assign(:linked_user, user)
           |> assign(:linked_account_path, Paths.user_view(user.uuid))
           |> put_flash(:info, gettext("Mirror account created and linked"))}

        {:error, :already_linked} ->
          {:noreply,
           put_flash(socket, :error, gettext("This company already has a mirror account"))}

        {:error, other} ->
          Logger.warning("[CRM] create_mirror_user failed: #{inspect(other)}")
          {:noreply, put_flash(socket, :error, gettext("Could not create a mirror account"))}
      end
    else
      # Defense in depth — the panel already hides this button when org
      # accounts are disabled, but a forged event must still be rejected.
      {:noreply,
       put_flash(socket, :error, gettext("Organization accounts are disabled in Settings"))}
    end
  end

  def handle_event("mirror_open_picker", _params, socket) do
    linked = Companies.linked_user_uuids()
    candidates = Enum.reject(Auth.list_organizations(), &MapSet.member?(linked, &1.uuid))

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
    company = socket.assigns.company

    case Auth.get_user(user_uuid) do
      %User{account_type: "organization"} = user ->
        # Re-check even though connect_user/2 also guards — the diff/fill
        # path below writes to `user` directly and must not run against a
        # type connect_user would reject anyway.
        case Mirror.diff(company, user) do
          [] ->
            link_without_conflict(socket, company, user)

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
         put_flash(socket, :error, gettext("Only organization accounts can mirror a company"))}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("That account no longer exists"))}
    end
  end

  # Keeps the modal's radio selections in server assigns (@mirror_choices)
  # rather than trusting the DOM — see MirrorConflictModal's moduledoc for
  # why an uncontrolled radio is a real bug here (a selection made just
  # before an unrelated re-render would otherwise silently revert to
  # @master). Filtered against @mirror_conflicts (the modal-open-time
  # diff — cheap, no DB hit; the DB-backed re-check happens at resolve
  # time, below) so a forged field name is dropped, not stored.
  def handle_event("mirror_choice_changed", %{"choices" => raw_choices}, socket) do
    allowed = allowed_conflict_fields(socket.assigns.mirror_conflicts)
    updates = atomize_choices(raw_choices, allowed)

    {:noreply, update(socket, :mirror_choices, &Map.merge(&1, updates))}
  end

  def handle_event("mirror_choice_changed", _params, socket), do: {:noreply, socket}

  def handle_event("mirror_resolve", %{"choices" => raw_choices}, socket) do
    # Re-fetch BOTH sides fresh rather than trusting socket.assigns.company
    # or the cached @mirror_conflicts — either record may have changed
    # (another session, another tab) while the modal sat open. The fresh
    # Mirror.diff/2 below is what "a field that stopped diverging is
    # dropped, not blindly applied" actually means; Mirror.resolve/4 also
    # re-checks divergence per field internally (the C-hardening guard),
    # so this is belt-and-suspenders, not redundant with nothing.
    company = Companies.get_company(socket.assigns.company.uuid)
    user = Auth.get_user(socket.assigns.mirror_pending_user_uuid)

    case {company, user} do
      {%Company{}, %User{}} ->
        fresh_conflicts = Mirror.diff(company, user)
        choices = atomize_choices(raw_choices, allowed_conflict_fields(fresh_conflicts))
        deltas = Mirror.resolve(:company, company, user, choices)

        case Companies.apply_mirror_resolution(company, user, deltas) do
          {:ok, {linked_company, linked_user}} ->
            {:noreply,
             socket
             |> assign(:company, linked_company)
             |> assign(:linked_user, linked_user)
             |> assign(:linked_account_path, Paths.user_view(linked_user.uuid))
             |> close_conflict()
             |> put_flash(:info, gettext("Mirror account linked"))}

          {:error, other} ->
            Logger.warning(
              "[CRM] mirror_resolve failed (company=#{inspect(company.uuid)}): #{inspect(other)}"
            )

            {:noreply,
             socket
             |> close_conflict()
             |> put_flash(:error, gettext("Could not apply the resolution — please try again"))}
        end

      _ ->
        Logger.warning(
          "[CRM] mirror_resolve: company or user missing (company_uuid=#{inspect(socket.assigns.company.uuid)}, " <>
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

  def handle_event("mirror_unlink", _params, socket) do
    case Companies.disconnect_user(socket.assigns.company) do
      {:ok, company} ->
        {:noreply,
         socket
         |> assign(:company, company)
         |> assign(:linked_user, nil)
         |> assign(:linked_account_path, nil)
         |> put_flash(:info, gettext("Mirror account unlinked"))}

      {:error, other} ->
        Logger.warning("[CRM] disconnect_user failed: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, gettext("Could not unlink the mirror account"))}
    end
  end

  # Ignore unexpected/forged events (and malformed validate/save payloads).
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp link_without_conflict(socket, company, user) do
    case Companies.connect_user(company, user.uuid) do
      {:ok, linked_company} ->
        linked_user = fill_blank_user_fields(user, company)

        {:noreply,
         socket
         |> assign(:company, linked_company)
         |> assign(:linked_user, linked_user)
         |> assign(:linked_account_path, Paths.user_view(linked_user.uuid))
         |> assign(:show_picker, false)
         |> assign(:picker_candidates, [])
         |> put_flash(:info, gettext("Linked to mirror account"))}

      {:error, other} ->
        Logger.warning("[CRM] connect_user failed: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, gettext("Could not link this account"))}
    end
  end

  # Best-effort secondary write (mirrors the apply_membership/apply_login
  # pattern in ContactFormLive) — only fills fields the user side is
  # currently BLANK on; a matching non-blank value is never touched. A
  # failure here doesn't undo the link, only logs.
  defp fill_blank_user_fields(user, company) do
    attrs =
      :company
      |> Mirror.attrs_from(company)
      |> Map.take([:organization_name, :email])
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

  defp close_conflict(socket) do
    socket
    |> assign(:mirror_conflicts, [])
    |> assign(:mirror_choices, %{})
    |> assign(:show_conflict, false)
    |> assign(:mirror_pending_user_uuid, nil)
  end

  defp allowed_conflict_fields(conflicts), do: conflicts |> Enum.map(& &1.field) |> MapSet.new()

  # Whitelisted conversion — never String.to_atom/1 (atom-exhaustion DoS)
  # or String.to_existing_atom/1 (raises and crashes the LiveView on a
  # crafted key) a submitted param directly. Doubly filtered: the field
  # name must be one of the two fields this kind ever mirrors AND must be
  # in `allowed_fields` (the fields actually diverging right now, per
  # @mirror_conflicts or a fresh Mirror.diff/2 — see call sites). Unknown
  # field names, non-diverging fields, and unrecognized choice values are
  # all silently dropped rather than raising on a forged payload.
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

  defp picker_label(%User{organization_name: name, email: email})
       when is_binary(name) and name != "",
       do: "#{name} — #{email}"

  defp picker_label(%User{email: email}), do: email

  defp blank?(v), do: is_nil(v) or (is_binary(v) and String.trim(v) == "")

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
    linked_user = linked_user_for(company)

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
     |> assign(:form, to_form(Companies.change_company(company)))
     |> assign(:linked_user, linked_user)
     |> assign(:linked_account_path, linked_user && Paths.user_view(linked_user.uuid))}
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

      <%!--
        A separate card, not inside the form above: this panel and its picker
        fire their own phx-submit ("mirror_link"), and HTML doesn't allow a
        <form> nested inside another <form> — the company save form above
        must stay self-contained.
      --%>
      <div :if={@company.uuid} class="card bg-base-100 shadow-sm mt-4">
        <div class="card-body flex flex-col gap-3">
          <div class="text-sm font-semibold text-base-content/60">{gettext("Mirror account")}</div>

          <.mirror_panel
            kind={:company}
            linked_user={@linked_user}
            can_link={@org_accounts_enabled}
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

      <p :if={!@company.uuid} class="mt-4 text-xs text-base-content/50">
        {gettext("Save the company first to link or create a mirror account.")}
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

  defp status_options, do: Enum.map(Company.statuses(), &{status_label(&1), &1})

  defp status_label("active"), do: gettext("Active")
  defp status_label("inactive"), do: gettext("Inactive")
  defp status_label(s), do: s

  defp safe_map(p) when is_map(p), do: p
  defp safe_map(_), do: %{}
end
