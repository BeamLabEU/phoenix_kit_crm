defmodule PhoenixKitCRM.Web.OrganizationsView do
  @moduledoc """
  Admin LiveView for the CRM Organizations subtab — lists users whose
  `account_type = "organization"` with per-user persisted column
  configuration. Supports a card/table view toggle (provided by
  `PhoenixKitWeb.Components.Core.TableDefault`).

  Gated by `PhoenixKitCRM.enabled?()` and the PhoenixKit-wide
  `enable_organization_accounts` setting.
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitCRM.Web.ColumnManagement
  use Gettext, backend: PhoenixKitCRM.Gettext

  # `row_link/1` isn't part of the `:live_view` macro's default import set
  # (confirmed: absent from `phoenix_kit_web.ex`'s `import` list), so each
  # consumer imports it explicitly — the same `only:` form core's own
  # `users.ex`/`activity/index.ex` use, restricted to keep this module's own
  # `render_cell/3` clause dispatch unambiguous.
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]
  import PhoenixKitCRM.Web.Components.MirrorConflictModal, only: [mirror_conflict_modal: 1]

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{ColumnConfig, Companies, Mirror, Paths, Web.CellFormat, Web.ColumnModal}
  alias PhoenixKitCRM.Schemas.Company

  alias PhoenixKitWeb.Components.Core.TableDefault

  # Whitelist for the conflict-resolution form's per-field radios — never
  # `String.to_atom/1` (atom-exhaustion) or `String.to_existing_atom/1`
  # (crashes the LiveView on a crafted key) a submitted param directly.
  @resolvable_fields %{"name" => :name, "email" => :email}

  @impl true
  def mount(_params, _session, socket) do
    cond do
      not PhoenixKitCRM.enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, gettext("CRM is not enabled."))
         |> push_navigate(to: Paths.index(), replace: true)}

      not Settings.get_boolean_setting("enable_organization_accounts", false) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Organization accounts are not enabled."))
         |> push_navigate(to: Paths.index(), replace: true)}

      true ->
        current_user = socket.assigns.phoenix_kit_current_user

        {:ok,
         socket
         |> assign(:page_title, gettext("CRM — Organizations"))
         |> assign(:scope, :organizations)
         |> assign(:current_user_uuid, current_user.uuid)
         |> assign(:users, [])
         |> assign(:selected_columns, ColumnConfig.default_columns(:organizations))
         |> assign(:column_meta, ColumnConfig.column_metadata_map(:organizations))
         |> assign(:show_column_modal, false)
         |> assign(:temp_selected_columns, nil)
         |> assign_mirror_defaults()}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if connected?(socket) do
      users = Auth.list_organizations()
      selected = ColumnConfig.get_columns(socket.assigns.current_user_uuid, :organizations)
      companies_by_user = Companies.map_by_user_uuids(Enum.map(users, & &1.uuid))

      {:noreply,
       socket
       |> assign(:users, users)
       |> assign(:companies_by_user, companies_by_user)
       |> assign(:selected_columns, selected)
       |> assign(:column_meta, ColumnConfig.column_metadata_map(:organizations))}
    else
      {:noreply, socket}
    end
  end

  defp assign_mirror_defaults(socket) do
    socket
    |> assign(:companies_by_user, %{})
    |> assign(:mirror_conflicts, [])
    |> assign(:mirror_choices, %{})
    |> assign(:mirror_pending, nil)
    |> assign(:show_conflict, false)
    |> assign(:show_picker, false)
    |> assign(:picker_user_uuid, nil)
    |> assign(:picker_candidates, [])
  end

  # ── Reverse mirror: create/link a Company FROM an organization-user ──
  #
  # The USER is master here (`master: :user`) — this view IS the "form"
  # transferring from the user side, unlike the Company/Contact forms
  # (Tasks G/H) where the CRM record is master. The conflict modal is
  # SHARED across every row on this list — exactly one pending
  # {user_uuid, company_uuid} pair lives in @mirror_pending at a time,
  # cleared on open/close so state can't leak between rows.

  @impl true
  def handle_event("mirror_create_company", %{"user_uuid" => user_uuid}, socket) do
    case Auth.get_user(user_uuid) do
      %User{account_type: "organization"} = user ->
        case Companies.create_from_user(user) do
          {:ok, company} ->
            {:noreply,
             socket
             |> update(:companies_by_user, &Map.put(&1, user_uuid, company))
             |> put_flash(:info, gettext("CRM company created and linked"))}

          {:error, {:already_linked, _existing}} ->
            {:noreply,
             put_flash(socket, :error, gettext("This account already has a linked company"))}

          {:error, other} ->
            Logger.warning("[CRM] create_from_user failed: #{inspect(other)}")
            {:noreply, put_flash(socket, :error, gettext("Could not create a company"))}
        end

      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Only organization accounts can mirror a company"))}
    end
  end

  def handle_event("mirror_open_company_picker", %{"user_uuid" => user_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:show_picker, true)
     |> assign(:picker_user_uuid, user_uuid)
     |> assign(:picker_candidates, Companies.list_unlinked_companies())}
  end

  def handle_event("mirror_close_company_picker", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_picker, false)
     |> assign(:picker_user_uuid, nil)
     |> assign(:picker_candidates, [])}
  end

  def handle_event(
        "mirror_link_company",
        %{"user_uuid" => user_uuid, "company_uuid" => company_uuid},
        socket
      ) do
    user = Auth.get_user(user_uuid)
    company = Companies.get_company(company_uuid)

    cond do
      is_nil(user) or is_nil(company) ->
        {:noreply, put_flash(socket, :error, gettext("That account or company no longer exists"))}

      user.account_type != "organization" ->
        {:noreply,
         put_flash(socket, :error, gettext("Only organization accounts can mirror a company"))}

      not is_nil(company.user_uuid) ->
        {:noreply,
         put_flash(socket, :error, gettext("That company is already linked to another account"))}

      true ->
        case Mirror.diff(company, user) do
          [] ->
            link_without_conflict(socket, company, user)

          conflicts ->
            {:noreply,
             socket
             |> assign(:mirror_conflicts, conflicts)
             |> assign(:mirror_choices, %{})
             |> assign(:mirror_pending, %{user_uuid: user_uuid, company_uuid: company_uuid})
             |> assign(:show_conflict, true)
             |> assign(:show_picker, false)
             |> assign(:picker_user_uuid, nil)
             |> assign(:picker_candidates, [])}
        end
    end
  end

  # Keeps the modal's radio selections in server assigns (@mirror_choices)
  # rather than trusting the DOM — see MirrorConflictModal's moduledoc.
  # Filtered against @mirror_conflicts (the modal-open-time diff — cheap,
  # no DB hit; the DB-backed re-check happens at resolve time, below).
  def handle_event("mirror_choice_changed", %{"choices" => raw_choices}, socket) do
    allowed = allowed_conflict_fields(socket.assigns.mirror_conflicts)
    updates = atomize_choices(raw_choices, allowed)

    {:noreply, update(socket, :mirror_choices, &Map.merge(&1, updates))}
  end

  def handle_event("mirror_choice_changed", _params, socket), do: {:noreply, socket}

  def handle_event("mirror_resolve", %{"choices" => raw_choices}, socket) do
    case socket.assigns.mirror_pending do
      %{user_uuid: user_uuid, company_uuid: company_uuid} ->
        # Re-fetch BOTH sides fresh — either record may have changed while
        # the modal sat open. Mirror.resolve/4 also re-checks divergence
        # per field internally (the Task C hardening guard), so this is
        # belt-and-suspenders, not redundant with nothing.
        company = Companies.get_company(company_uuid)
        user = Auth.get_user(user_uuid)

        case {company, user} do
          {%Company{}, %User{}} ->
            fresh_conflicts = Mirror.diff(company, user)
            choices = atomize_choices(raw_choices, allowed_conflict_fields(fresh_conflicts))
            deltas = Mirror.resolve(:company, company, user, choices)

            case Companies.apply_mirror_resolution(company, user, deltas) do
              {:ok, {linked_company, _linked_user}} ->
                {:noreply,
                 socket
                 |> update(:companies_by_user, &Map.put(&1, user_uuid, linked_company))
                 |> close_conflict()
                 |> put_flash(:info, gettext("Mirror account linked"))}

              {:error, other} ->
                Logger.warning(
                  "[CRM] mirror_resolve failed (company=#{inspect(company_uuid)}): #{inspect(other)}"
                )

                {:noreply,
                 socket
                 |> close_conflict()
                 |> put_flash(
                   :error,
                   gettext("Could not apply the resolution — please try again")
                 )}
            end

          _ ->
            Logger.warning(
              "[CRM] mirror_resolve: company or user missing (company_uuid=#{inspect(company_uuid)}, user_uuid=#{inspect(user_uuid)})"
            )

            {:noreply,
             socket
             |> close_conflict()
             |> put_flash(:error, gettext("Could not apply the resolution — please try again"))}
        end

      nil ->
        {:noreply, close_conflict(socket)}
    end
  end

  def handle_event("mirror_cancel_conflict", _params, socket) do
    {:noreply, close_conflict(socket)}
  end

  defp link_without_conflict(socket, company, user) do
    case Companies.connect_user(company, user.uuid) do
      {:ok, linked_company} ->
        linked_company = fill_blank_company_fields(linked_company, user)

        {:noreply,
         socket
         |> update(:companies_by_user, &Map.put(&1, user.uuid, linked_company))
         |> assign(:show_picker, false)
         |> assign(:picker_user_uuid, nil)
         |> assign(:picker_candidates, [])
         |> put_flash(:info, gettext("Linked to CRM company"))}

      {:error, other} ->
        Logger.warning("[CRM] connect_user failed: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, gettext("Could not link this company"))}
    end
  end

  # Best-effort secondary write (same discipline as G/H's blank-fill) —
  # reverse direction: only fills COMPANY fields that are currently BLANK,
  # sourced from the user (master here). A matching non-blank value is
  # never touched; a failure here doesn't undo the link, only logs.
  defp fill_blank_company_fields(company, user) do
    attrs =
      :company
      |> Mirror.attrs_to_crm(user)
      |> Enum.filter(fn {field, value} ->
        not is_nil(value) and blank?(Map.get(company, field))
      end)
      |> Map.new()

    if attrs == %{} do
      company
    else
      case Companies.update_company(company, attrs) do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          Logger.warning("[CRM] fill_blank_company_fields failed: #{inspect(changeset.errors)}")
          company
      end
    end
  end

  defp close_conflict(socket) do
    socket
    |> assign(:mirror_conflicts, [])
    |> assign(:mirror_choices, %{})
    |> assign(:show_conflict, false)
    |> assign(:mirror_pending, nil)
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

  defp blank?(v), do: is_nil(v) or (is_binary(v) and String.trim(v) == "")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <TableDefault.table_default
        id="crm-organizations-table"
        toggleable
        items={@users}
        card_title={fn u -> card_title_link(u) end}
        card_fields={fn u -> Enum.map(@selected_columns, &card_field(@column_meta, &1, u)) end}
      >
        <:toolbar_title>
          <span class="text-sm text-base-content/60">
            {ngettext("%{count} organization", "%{count} organizations", length(@users),
              count: length(@users)
            )}
          </span>
        </:toolbar_title>
        <:toolbar_actions>
          <button class="btn btn-outline btn-sm" phx-click="show_column_modal">
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4" /> {gettext("Columns")}
          </button>
        </:toolbar_actions>

        <TableDefault.table_default_header>
          <TableDefault.table_default_row>
            <TableDefault.table_default_header_cell :for={col <- @selected_columns}>
              {column_label(@column_meta, col)}
            </TableDefault.table_default_header_cell>
            <TableDefault.table_default_header_cell>
              {gettext("CRM company")}
            </TableDefault.table_default_header_cell>
          </TableDefault.table_default_row>
        </TableDefault.table_default_header>

        <TableDefault.table_default_body>
          <TableDefault.table_default_row
            :for={user <- @users}
            class="relative transform-gpu cursor-pointer"
          >
            <TableDefault.table_default_cell :for={{col, index} <- Enum.with_index(@selected_columns)}>
              <.row_link
                :if={index == 0}
                navigate={Paths.user_view(user.uuid)}
                label={Map.get(user, :organization_name) || user.email}
              />
              {render_cell(@column_meta, col, user)}
            </TableDefault.table_default_cell>
            <TableDefault.table_default_cell class="relative z-10">
              <.mirror_cell user={user} company={Map.get(@companies_by_user, user.uuid)} />
            </TableDefault.table_default_cell>
          </TableDefault.table_default_row>

          <TableDefault.table_default_row :if={@users == []}>
            <TableDefault.table_default_cell colspan={length(@selected_columns) + 1}>
              <div class="text-center text-base-content/50 py-8">
                {gettext("No organization accounts yet.")}
              </div>
            </TableDefault.table_default_cell>
          </TableDefault.table_default_row>
        </TableDefault.table_default_body>
      </TableDefault.table_default>

      <ColumnModal.column_modal
        show={@show_column_modal}
        scope={@scope}
        selected={@selected_columns}
        temp_selected={@temp_selected_columns}
      />

      <.modal
        :if={@show_picker}
        show={@show_picker}
        on_close="mirror_close_company_picker"
        id="mirror-company-picker-modal"
      >
        <:title>{gettext("Link existing company")}</:title>
        <.form
          for={%{}}
          id="mirror-company-picker-form"
          phx-submit="mirror_link_company"
          class="space-y-3"
        >
          <input type="hidden" name="user_uuid" value={@picker_user_uuid} />
          <.select
            id="mirror-company-picker-select"
            name="company_uuid"
            value={nil}
            prompt={gettext("— choose a company —")}
            options={Enum.map(@picker_candidates, &{&1.name, &1.uuid})}
          />
          <div class="modal-action">
            <.button type="button" variant="ghost" phx-click="mirror_close_company_picker">
              {gettext("Cancel")}
            </.button>
            <.button type="submit" variant="primary">{gettext("Link")}</.button>
          </div>
        </.form>
      </.modal>

      <.mirror_conflict_modal
        conflicts={@mirror_conflicts}
        master={:user}
        choices={@mirror_choices}
        show={@show_conflict}
      />
    </div>
    """
  end

  # The per-row "CRM company" cell: badge + link when linked, Create/Link
  # actions when not.
  attr(:user, :any, required: true)
  attr(:company, :any, default: nil)

  defp mirror_cell(assigns) do
    ~H"""
    <div :if={@company} class="flex items-center gap-2">
      <span class="badge badge-success badge-sm">{gettext("Linked")}</span>
      <.link navigate={Paths.company(@company.uuid)} class="link link-hover text-sm">
        {@company.name}
      </.link>
    </div>
    <div :if={!@company} class="flex flex-wrap gap-1">
      <.button
        phx-click="mirror_create_company"
        phx-value-user_uuid={@user.uuid}
        variant="primary"
        size="xs"
      >
        {gettext("Create CRM company")}
      </.button>
      <.button
        phx-click="mirror_open_company_picker"
        phx-value-user_uuid={@user.uuid}
        variant="outline"
        size="xs"
      >
        {gettext("Link existing…")}
      </.button>
    </div>
    """
  end

  defp column_label(column_meta, col) do
    case Map.get(column_meta, col) do
      %{label: label} -> label
      _ -> col
    end
  end

  defp card_field(column_meta, col, user),
    do: %{label: column_label(column_meta, col), value: render_cell(column_meta, col, user)}

  defp render_cell(_meta, "organization_name", u), do: Map.get(u, :organization_name) || "—"
  defp render_cell(_meta, "email", u), do: u.email
  defp render_cell(_meta, "username", u), do: Map.get(u, :username) || "—"
  defp render_cell(_meta, "full_name", u), do: full_name(u)
  defp render_cell(_meta, "status", u), do: crm_status_html(Map.get(u, :is_active))
  defp render_cell(_meta, "registered", u), do: format_date(Map.get(u, :inserted_at))
  defp render_cell(_meta, "location", u), do: location(u)

  defp render_cell(meta, "custom_" <> _ = col, u),
    do: CellFormat.render_custom_cell(meta, col, u)

  defp render_cell(_meta, _col, _u), do: "—"

  defp full_name(u) do
    [Map.get(u, :first_name), Map.get(u, :last_name)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> case do
      "" -> "—"
      n -> n
    end
  end

  defp card_title_link(u) do
    label = Map.get(u, :organization_name) || u.email
    assigns = %{href: Paths.user_view(u.uuid), label: label}
    ~H|<.link navigate={@href} class="link link-hover font-medium">{@label}</.link>|
  end

  defp crm_status_html(true) do
    assigns = %{}
    ~H|<.status_badge status="active" size={:sm} />|
  end

  defp crm_status_html(_) do
    assigns = %{}
    ~H|<.status_badge status="inactive" size={:sm} />|
  end

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(_), do: "—"

  defp location(u) do
    [Map.get(u, :registration_city), Map.get(u, :registration_country)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
    |> case do
      "" -> "—"
      l -> l
    end
  end
end
