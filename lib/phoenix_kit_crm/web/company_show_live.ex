defmodule PhoenixKitCRM.Web.CompanyShowLive do
  @moduledoc """
  Show page for a CRM company. Tabs: Overview (details + contacts), Interactions
  (a read-only rollup of interactions logged on the company's contacts), and
  Events always; Files + Images when core Storage is enabled; Comments when the
  comments module is enabled. The header shows a circular logo (icon fallback).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext
  # Forwards the comment composer's {:leaf_changed, …} into CommentsComponent.
  use PhoenixKitComments.Embed

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCRM.{Activity, Attachments, Companies, Paths}
  alias PhoenixKitCRM.Schemas.{Company, Contact}
  alias PhoenixKitCRM.Web.{CompanyInteractionsComponent, EventsComponent, MediaComponent}
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, show_avatar_picker: false, avatar_folder_uuid: nil)}

  @impl true
  def handle_params(params, _uri, socket) do
    case Companies.get_company(params["uuid"]) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Company not found"))
         |> push_navigate(to: Paths.companies())}

      company ->
        storage_enabled = storage_enabled?()
        comments_enabled = comments_available?()

        tab =
          if params["tab"] in valid_tabs(storage_enabled, comments_enabled),
            do: params["tab"],
            else: "overview"

        {:noreply,
         socket
         |> assign(:company, company)
         |> assign(:tab, tab)
         |> assign(:storage_enabled, storage_enabled)
         |> assign(:comments_enabled, comments_enabled)
         |> assign(:avatar_url, Attachments.avatar_url(company))
         |> assign(:tz_offset, tz_offset(socket.assigns[:phoenix_kit_current_user]))
         |> assign(:page_title, Company.display_name(company))
         |> assign(:page_section, gettext("Companies"))
         |> assign(:page_section_path, Paths.companies())
         |> assign(:memberships, Companies.list_memberships(company.uuid))}
    end
  end

  @impl true
  # The media component (a LiveComponent) routes flash + logo refreshes up here.
  def handle_info({:put_flash, kind, msg}, socket), do: {:noreply, put_flash(socket, kind, msg)}

  def handle_info({:avatar_changed}, socket) do
    company = Companies.get_company(socket.assigns.company.uuid) || socket.assigns.company

    {:noreply,
     socket |> assign(:company, company) |> assign(:avatar_url, Attachments.avatar_url(company))}
  end

  # Header-logo picker (a MediaSelectorModal with no `notify`) delivers its
  # result here; the Files/Images tab pickers notify their own component.
  def handle_info({:media_selected, [uuid | _]}, socket) when is_binary(uuid) do
    case Attachments.set_avatar(:company, socket.assigns.company, uuid) do
      {:ok, _} ->
        log_avatar(socket, "set")
        send(self(), {:avatar_changed})

      _ ->
        :ok
    end

    {:noreply, assign(socket, :show_avatar_picker, false)}
  end

  def handle_info({:media_selected, _}, socket),
    do: {:noreply, assign(socket, :show_avatar_picker, false)}

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, assign(socket, :show_avatar_picker, false)}

  def handle_info(msg, socket) do
    Logger.debug("[CRM] CompanyShowLive ignoring message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Open the logo picker scoped to the company's Images folder.
  @impl true
  def handle_event("edit_avatar", _params, socket) do
    cond do
      not socket.assigns.storage_enabled ->
        {:noreply, socket}

      Company.trashed?(socket.assigns.company) ->
        {:noreply,
         put_flash(socket, :error, gettext("Restore this company before changing its logo."))}

      true ->
        case Attachments.ensure_folder(
               :company,
               socket.assigns.company.uuid,
               :images,
               actor_uuid(socket)
             ) do
          {:ok, folder_uuid} ->
            {:noreply, assign(socket, avatar_folder_uuid: folder_uuid, show_avatar_picker: true)}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not open the image picker."))}
        end
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    case Attachments.clear_avatar(socket.assigns.company) do
      {:ok, _} ->
        log_avatar(socket, "removed")
        send(self(), {:avatar_changed})
        {:noreply, socket}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not remove the logo."))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp log_avatar(socket, verb) do
    Activity.log("crm.company_avatar_#{verb}",
      actor_uuid: actor_uuid(socket),
      resource_type: "crm_company",
      resource_uuid: socket.assigns.company.uuid,
      metadata: %{}
    )
  end

  defp tab_defs(storage_enabled?, comments_enabled?) do
    [
      {"overview", gettext("Overview"), "hero-identification"},
      {"members", gettext("Members"), "hero-users"},
      {"interactions", gettext("Interactions"), "hero-chat-bubble-left-right"},
      {"events", gettext("Events"), "hero-clock"}
    ]
    |> maybe_concat(storage_enabled?, [
      {"files", gettext("Files"), "hero-document"},
      {"images", gettext("Images"), "hero-photo"}
    ])
    |> maybe_concat(comments_enabled?, [
      {"comments", gettext("Comments"), "hero-chat-bubble-bottom-center-text"}
    ])
  end

  defp maybe_concat(list, true, extra), do: list ++ extra
  defp maybe_concat(list, false, _extra), do: list

  defp valid_tabs(storage_enabled?, comments_enabled?),
    do:
      Enum.map(tab_defs(storage_enabled?, comments_enabled?), fn {value, _label, _icon} ->
        value
      end)

  defp tab_path(uuid, "overview"), do: Paths.company(uuid)
  defp tab_path(uuid, tab), do: Paths.company(uuid) <> "?tab=#{tab}"

  defp storage_enabled? do
    Storage.enabled?()
  rescue
    _ -> false
  end

  defp comments_available? do
    Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col px-4 py-6 gap-6">
      <div class="flex items-center justify-between flex-wrap gap-2">
        <div class="flex items-center gap-3">
          <.company_logo url={@avatar_url} storage_enabled={@storage_enabled} />
          <.status_badge status={@company.status} size={:sm} />
        </div>
        <.link navigate={Paths.company_edit(@company.uuid)} class="btn btn-outline btn-sm">
          <.icon name="hero-pencil-square" class="w-4 h-4" /> {gettext("Edit")}
        </.link>
      </div>

      <div role="tablist" class="tabs tabs-bordered">
        <.link
          :for={{value, label, icon} <- tab_defs(@storage_enabled, @comments_enabled)}
          patch={tab_path(@company.uuid, value)}
          role="tab"
          class={["tab gap-1.5", @tab == value && "tab-active"]}
        >
          <.icon name={icon} class="w-4 h-4" /> {label}
        </.link>
      </div>

      <div :if={@tab == "overview"} class="card bg-base-100 shadow-sm">
        <div class="card-body grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-3">
          <.field label={gettext("Website")} value={@company.website} />
          <.field label={gettext("Email")} value={@company.email} />
          <.field label={gettext("Phone")} value={@company.phone} />
          <.field label={gettext("Industry")} value={@company.industry} />
          <div class="sm:col-span-2"><.field label={gettext("Address")} value={@company.address} /></div>
          <div class="sm:col-span-2"><.field label={gettext("Notes")} value={@company.notes} /></div>
        </div>
      </div>

      <div :if={@tab == "members"} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title text-lg">
            <.icon name="hero-users" class="w-5 h-5" /> {gettext("Members")} ({length(@memberships)})
          </h2>

          <.empty_state
            :if={@memberships == []}
            icon="hero-users"
            title={gettext("No contacts linked to this company yet — set a contact's company on their edit page.")}
          />

          <ul :if={@memberships != []} class="flex flex-col divide-y divide-base-200">
            <li :for={m <- @memberships} class="flex items-center gap-3 py-2.5">
              <.member_avatar contact={m.contact} />
              <div class="flex-1 min-w-0">
                <.link
                  :if={m.contact}
                  navigate={Paths.contact(m.contact.uuid)}
                  class="font-medium link link-hover"
                >
                  {Contact.display_name(m.contact)}
                </.link>
                <span :if={!m.contact} class="font-medium">{gettext("Unknown")}</span>
                <div :if={member_role(m) != ""} class="text-xs text-base-content/60">{member_role(m)}</div>
              </div>
              <span
                :if={m.contact && m.contact.email}
                class="text-xs text-base-content/50 hidden sm:block truncate max-w-[14rem]"
              >
                {m.contact.email}
              </span>
              <span
                :if={m.contact && m.contact.user_uuid}
                class="badge badge-success badge-sm gap-1 shrink-0"
              >
                <.icon name="hero-key-mini" class="w-3 h-3" /> {gettext("Login")}
              </span>
            </li>
          </ul>
        </div>
      </div>

      <div :if={@tab == "interactions"}>
        <.live_component
          module={CompanyInteractionsComponent}
          id={"crm-company-interactions-#{@company.uuid}"}
          company={@company}
          tz_offset={@tz_offset}
        />
      </div>

      <div :if={@tab == "events"}>
        <.live_component
          module={EventsComponent}
          id={"crm-company-events-#{@company.uuid}"}
          resource_type="crm_company"
          resource_uuid={@company.uuid}
          tz_offset={@tz_offset}
        />
      </div>

      <div :if={@tab == "files"}>
        <.live_component
          module={MediaComponent}
          id={"crm-company-files-#{@company.uuid}"}
          kind={:files}
          resource_type={:company}
          resource={@company}
          phoenix_kit_current_user={@phoenix_kit_current_user}
        />
      </div>

      <div :if={@tab == "images"}>
        <.live_component
          module={MediaComponent}
          id={"crm-company-images-#{@company.uuid}"}
          kind={:images}
          resource_type={:company}
          resource={@company}
          phoenix_kit_current_user={@phoenix_kit_current_user}
        />
      </div>

      <div :if={@tab == "comments"}>
        <.live_component
          module={PhoenixKitComments.Web.CommentsComponent}
          id={"crm-company-comments-#{@company.uuid}"}
          resource_type="crm_company"
          resource_uuid={@company.uuid}
          current_user={@phoenix_kit_current_user}
        />
      </div>

      <%!-- Header-logo picker (Images folder; no `notify` → result lands in
           this LV's handle_info). --%>
      <.live_component
        :if={@show_avatar_picker}
        module={MediaSelectorModal}
        id={"crm-company-avatar-#{@company.uuid}"}
        show={true}
        mode={:single}
        file_type_filter={:image}
        browse={true}
        selected_uuids={Enum.reject([Attachments.avatar_uuid(@company)], &is_nil/1)}
        scope_folder_id={@avatar_folder_uuid}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />
    </div>
    """
  end

  # Circular company logo (header) — click to set/change (Storage required),
  # hover to remove when set. Image if set, else a building icon.
  attr(:url, :string, default: nil)
  attr(:storage_enabled, :boolean, default: false)

  defp company_logo(assigns) do
    ~H"""
    <div class="relative shrink-0 group">
      <button
        type="button"
        phx-click="edit_avatar"
        disabled={!@storage_enabled}
        class="block w-12 h-12 rounded-full overflow-hidden ring-1 ring-base-300 bg-base-300 disabled:cursor-default"
        aria-label={gettext("Change logo")}
      >
        <img :if={@url} src={@url} alt="" class="w-full h-full object-cover" />
        <span
          :if={!@url}
          class="flex items-center justify-center w-full h-full text-base-content/60"
        >
          <.icon name="hero-building-office-2" class="w-6 h-6" />
        </span>
        <span
          :if={@storage_enabled}
          class="absolute inset-0 hidden group-hover:flex items-center justify-center bg-black/40 text-white rounded-full"
        >
          <.icon name="hero-camera" class="w-4 h-4" />
        </span>
      </button>
      <button
        :if={@storage_enabled and @url}
        type="button"
        phx-click="remove_avatar"
        data-confirm={gettext("Remove this logo?")}
        class="absolute -top-1 -right-1 btn btn-xs btn-circle btn-error opacity-0 group-hover:opacity-100 transition"
        aria-label={gettext("Remove logo")}
      >
        <.icon name="hero-x-mark" class="w-3 h-3" />
      </button>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, default: nil)

  defp field(assigns) do
    ~H"""
    <div>
      <div class="text-xs uppercase tracking-wide text-base-content/50">{@label}</div>
      <div class="text-sm">{@value || "—"}</div>
    </div>
    """
  end

  # Small circular member avatar (real photo if set, else initials).
  attr(:contact, :map, default: nil)

  defp member_avatar(assigns) do
    assigns = assign(assigns, :url, assigns.contact && Attachments.avatar_url(assigns.contact))

    ~H"""
    <img
      :if={@url}
      src={@url}
      alt=""
      class="w-9 h-9 rounded-full object-cover ring-1 ring-base-300 shrink-0"
    />
    <div
      :if={!@url}
      class="w-9 h-9 rounded-full bg-base-300 text-base-content/60 flex items-center justify-center text-sm font-semibold shrink-0"
    >
      {member_initials(@contact)}
    </div>
    """
  end

  defp member_initials(%Contact{} = c) do
    c
    |> Contact.display_name()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp member_initials(_), do: "?"

  defp member_role(m),
    do: [m.role_in_company, m.department] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  defp tz_offset(%{} = user) do
    case PhoenixKit.Utils.Date.get_user_timezone(user) do
      off when is_binary(off) ->
        case Integer.parse(off) do
          {hours, _} -> hours
          _ -> 0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp tz_offset(_), do: 0
end
