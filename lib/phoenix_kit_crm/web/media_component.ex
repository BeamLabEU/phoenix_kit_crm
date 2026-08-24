defmodule PhoenixKitCRM.Web.MediaComponent do
  @moduledoc """
  The **Files** and **Images** tabs for a CRM record (a contact or a company),
  parameterized by `:resource_type` (`:contact | :company`), the `:resource`
  struct, and `:kind` (`:files | :images`). Media is folder-scoped via core
  `PhoenixKit.Modules.Storage` (see `PhoenixKitCRM.Attachments`): a
  `crm-<resource>-<uuid>` root folder for `:files`, a nested `Images` subfolder
  for `:images`.

  Upload/browse is delegated to core's `MediaSelectorModal` (scoped to the
  folder; the modal owns its own `allow_upload`). The modal `notify`s its result
  back; we attach each file and refresh. Removal soft-trashes a sole-owner file
  or unlinks a shared one. Every add/remove is activity-logged so it surfaces on
  the Events tab. The Images tab can set the record's avatar (contact photo /
  company logo). On the contact Files tab, files attached to that contact's
  interactions roll up read-only.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCRM.{Activity, Attachments, Interactions}
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  # ── Updates ────────────────────────────────────────────────────────

  # Modal results delivered via `notify: {__MODULE__, id}`.
  @impl true
  def update(%{media_selected: uuids}, socket) when is_list(uuids) do
    {:ok, socket |> attach_selected(uuids) |> close_picker() |> reload()}
  end

  def update(%{media_selector_closed: true}, socket), do: {:ok, close_picker(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    kind = socket.assigns.kind
    rtype = socket.assigns.resource_type
    record = socket.assigns.resource
    key = {record.uuid, kind}

    # `avatar_uuid` is a cheap metadata read — keep it current so an avatar set
    # elsewhere (e.g. the header picker) reflects here. The folder/file/rollup
    # queries only change when the record or tab does, so guard them: the
    # component reloads its own files after each add/remove, and the host never
    # relies on update/2 to refresh media content.
    socket =
      socket
      |> assign_new(:show_picker, fn -> false end)
      |> assign(:avatar_uuid, Attachments.avatar_uuid(record))
      |> assign(:avatar_noun, avatar_noun(rtype))

    cond do
      socket.assigns[:loaded_key] != key ->
        {:ok,
         socket
         |> assign(:folder_uuid, Attachments.folder_uuid(rtype, record.uuid, kind))
         |> assign(:rollup_files, rollup_files(rtype, record.uuid, kind))
         |> assign(:loaded_key, key)
         |> assign(:loaded_token, socket.assigns[:refresh_token])
         |> reload()}

      # The host's PubSub-driven send_update: the interaction roll-up (files
      # attached to this contact's interactions) changed under us. Only that
      # list is re-queried — the folder's own files are managed here and
      # reloaded after each add/remove already.
      socket.assigns[:refresh_token] != socket.assigns[:loaded_token] ->
        {:ok,
         socket
         |> assign(:rollup_files, rollup_files(rtype, record.uuid, kind))
         |> assign(:loaded_token, socket.assigns[:refresh_token])}

      true ->
        {:ok, socket}
    end
  end

  # The contact Files tab rolls up files attached to that contact's interactions
  # (read-only here — managed on the interaction). Companies have no interactions.
  defp rollup_files(:contact, contact_uuid, :files) do
    contact_uuid
    |> Interactions.interaction_uuids_for_contact()
    |> Attachments.list_files_by_interaction()
    |> Map.values()
    |> List.flatten()
  end

  defp rollup_files(_rtype, _uuid, _kind), do: []

  defp avatar_noun(:company), do: gettext("logo")
  defp avatar_noun(_), do: gettext("profile photo")

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_picker", _params, socket) do
    case ensure_folder(socket) do
      {:ok, folder_uuid} ->
        {:noreply, assign(socket, folder_uuid: folder_uuid, show_picker: true)}

      {:error, _reason} ->
        {:noreply, put_flash_safe(socket, :error, gettext("Could not prepare the media folder."))}
    end
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, close_picker(socket)}

  # Set one of the record's images as its avatar. The host owns the header
  # avatar, so notify it to reload after the metadata write.
  def handle_event("set_as_avatar", %{"uuid" => uuid}, socket) do
    case Attachments.set_avatar(socket.assigns.resource_type, socket.assigns.resource, uuid) do
      {:ok, _} ->
        Activity.log("crm.#{socket.assigns.resource_type}_avatar_set",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: activity_resource_type(socket),
          resource_uuid: socket.assigns.resource.uuid,
          metadata: %{}
        )

        send(self(), {:avatar_changed})

        {:noreply,
         socket
         |> assign(:avatar_uuid, uuid)
         |> put_flash_safe(:info, gettext("Saved."))}

      {:error, _} ->
        {:noreply, put_flash_safe(socket, :error, gettext("Could not set the image."))}
    end
  end

  def handle_event("remove_file", %{"uuid" => uuid}, socket) do
    if storage_enabled?() do
      case Attachments.detach(uuid, socket.assigns.folder_uuid) do
        :ok ->
          log(socket, "removed", %{"file_uuid" => uuid})
          {:noreply, socket |> maybe_clear_avatar(uuid) |> reload()}

        {:error, reason} ->
          Logger.warning("[CRM] remove #{noun(socket)} failed: #{inspect(reason)}")
          {:noreply, put_flash_safe(socket, :error, gettext("Could not remove the file."))}
      end
    else
      {:noreply, reload(socket)}
    end
  end

  # If the removed image was the avatar, clear the pointer so the header doesn't
  # reference a trashed file, and tell the host to refresh.
  defp maybe_clear_avatar(socket, uuid) do
    if uuid == socket.assigns[:avatar_uuid] do
      Attachments.clear_avatar(socket.assigns.resource)
      send(self(), {:avatar_changed})
      assign(socket, :avatar_uuid, nil)
    else
      socket
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp ensure_folder(socket) do
    Attachments.ensure_folder(
      socket.assigns.resource_type,
      socket.assigns.resource.uuid,
      socket.assigns.kind,
      Activity.actor_uuid(socket)
    )
  end

  # Attach each selected/uploaded file to the folder (uploads are already home
  # there; library-picks get linked). Gated on storage being enabled. Each tab
  # enforces its type here — Images keeps only images, Files keeps only non-
  # images — rejecting (and sweeping out) anything of the wrong type.
  defp attach_selected(socket, []), do: socket

  defp attach_selected(socket, uuids) do
    if storage_enabled?() do
      case ensure_folder(socket) do
        {:ok, folder_uuid} -> do_attach(socket, folder_uuid, uuids)
        {:error, _} -> socket
      end
    else
      socket
    end
  end

  defp do_attach(socket, folder_uuid, uuids) do
    # Don't add media to a trashed record (the soft-delete contract). Reachable
    # because the tab stays interactive on a trashed record; this is the backstop.
    if socket.assigns.resource.status == "trashed" do
      put_flash_safe(
        socket,
        :error,
        gettext("This record is in the trash — restore it before adding media.")
      )
    else
      {accepted, rejected} = partition_for_kind(socket.assigns.kind, uuids)

      Enum.each(accepted, &Attachments.attach(&1, folder_uuid))
      # A non-image uploaded via the picker lands in the folder as home; drop it.
      Enum.each(rejected, &Attachments.detach(&1, folder_uuid))

      if accepted != [], do: log(socket, "added", %{"count" => length(accepted)})

      socket
      |> assign(:folder_uuid, folder_uuid)
      |> flash_rejected(rejected)
    end
  end

  defp partition_for_kind(:images, uuids), do: Enum.split_with(uuids, &Attachments.image?/1)

  defp partition_for_kind(:files, uuids),
    do: Enum.split_with(uuids, &(not Attachments.image?(&1)))

  defp partition_for_kind(_kind, uuids), do: {uuids, []}

  defp flash_rejected(socket, []), do: socket

  defp flash_rejected(socket, rejected) do
    put_flash_safe(socket, :error, reject_message(socket.assigns.kind, length(rejected)))
  end

  defp reject_message(:images, count) do
    ngettext(
      "Only images can be added here — skipped %{count} non-image file.",
      "Only images can be added here — skipped %{count} non-image files.",
      count
    )
  end

  defp reject_message(_files, count) do
    ngettext(
      "Images belong in the Images tab — skipped %{count} image.",
      "Images belong in the Images tab — skipped %{count} images.",
      count
    )
  end

  defp close_picker(socket), do: assign(socket, :show_picker, false)

  defp reload(socket) do
    files =
      Attachments.list_files(socket.assigns.folder_uuid, only: only_for(socket.assigns.kind))

    assign(socket, :files, files)
  end

  defp only_for(:images), do: :images
  defp only_for(_files), do: :non_images

  defp log(socket, verb, metadata) do
    Activity.log("crm.#{socket.assigns.resource_type}_#{noun(socket)}_#{verb}",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: activity_resource_type(socket),
      resource_uuid: socket.assigns.resource.uuid,
      metadata: metadata
    )
  end

  defp activity_resource_type(socket), do: "crm_#{socket.assigns.resource_type}"

  defp noun(%{assigns: %{kind: :images}}), do: "image"
  defp noun(_), do: "file"

  defp storage_enabled? do
    Storage.enabled?()
  rescue
    _ -> false
  end

  defp put_flash_safe(socket, kind, msg) do
    send(self(), {:put_flash, kind, msg})
    socket
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <div class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <div class="flex items-center justify-between gap-2">
            <h2 class="card-title text-lg">
              <.icon name={if @kind == :images, do: "hero-photo", else: "hero-document"} class="w-5 h-5" />
              {if @kind == :images, do: gettext("Images"), else: gettext("Files")} ({length(@files)})
            </h2>
            <button type="button" phx-target={@myself} phx-click="open_picker" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4" />
              {if @kind == :images, do: gettext("Add images"), else: gettext("Add files")}
            </button>
          </div>

          <p :if={@files == []} class="text-sm text-base-content/60 py-2">
            {if @kind == :images, do: gettext("No images yet."), else: gettext("No files yet.")}
          </p>

          <%!-- Images: thumbnail grid --%>
          <div
            :if={@kind == :images and @files != []}
            class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3"
          >
            <div :for={f <- @files} class="relative group rounded-box overflow-hidden border border-base-300">
              <a href={Attachments.download_url(f)} target="_blank" rel="noopener" class="block aspect-square bg-base-200">
                <img
                  src={Attachments.thumb_url(f)}
                  alt={f.original_file_name || f.file_name}
                  loading="lazy"
                  class="w-full h-full object-cover"
                />
              </a>
              <button
                type="button"
                phx-target={@myself}
                phx-click="remove_file"
                phx-value-uuid={f.uuid}
                phx-disable-with={gettext("Deleting…")}
                data-confirm={gettext("Remove this image?")}
                class="btn btn-xs btn-circle btn-error absolute top-1 right-1 opacity-0 group-hover:opacity-100 transition"
                aria-label={gettext("Remove")}
              >
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
              </button>
              <%!-- Set as / current avatar --%>
              <button
                type="button"
                phx-target={@myself}
                phx-click="set_as_avatar"
                phx-value-uuid={f.uuid}
                disabled={f.uuid == @avatar_uuid}
                class={[
                  "btn btn-xs btn-circle absolute top-1 left-1 border-0 bg-base-100/80 transition",
                  if(f.uuid == @avatar_uuid, do: "opacity-100 text-warning", else: "opacity-0 group-hover:opacity-100")
                ]}
                title={
                  if(f.uuid == @avatar_uuid,
                    do: gettext("Current %{noun}", noun: @avatar_noun),
                    else: gettext("Set as %{noun}", noun: @avatar_noun))
                }
                aria-label={gettext("Set as %{noun}", noun: @avatar_noun)}
              >
                <.icon name="hero-star" class="w-3.5 h-3.5" />
              </button>
              <span :if={f.uuid == @avatar_uuid} class="badge badge-xs badge-primary absolute bottom-1 left-1">
                {@avatar_noun}
              </span>
            </div>
          </div>

          <%!-- Files: list --%>
          <ul :if={@kind == :files and @files != []} class="flex flex-col divide-y divide-base-200">
            <li :for={f <- @files} class="flex items-center gap-3 py-2">
              <.icon name={Attachments.file_icon(f)} class="w-5 h-5 text-base-content/60 shrink-0" />
              <div class="flex-1 min-w-0">
                <a href={Attachments.download_url(f)} target="_blank" rel="noopener" class="link link-hover font-medium block truncate">
                  {f.original_file_name || f.file_name}
                </a>
                <div class="text-xs text-base-content/50">{Attachments.format_file_size(f.size)}</div>
              </div>
              <button
                type="button"
                phx-target={@myself}
                phx-click="remove_file"
                phx-value-uuid={f.uuid}
                phx-disable-with={gettext("Deleting…")}
                data-confirm={gettext("Remove this file?")}
                class="btn btn-ghost btn-xs btn-square text-error shrink-0"
                aria-label={gettext("Remove")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </li>
          </ul>
        </div>
      </div>

      <%!-- Roll-up: files attached to this contact's interactions (read-only;
           managed on the interaction itself). --%>
      <div :if={@kind == :files and @rollup_files != []} class="card bg-base-100 shadow-sm">
        <div class="card-body">
          <h3 class="card-title text-base">
            <.icon name="hero-paper-clip" class="w-4 h-4" />
            {gettext("Attached to interactions")} ({length(@rollup_files)})
          </h3>
          <ul class="flex flex-col divide-y divide-base-200">
            <li :for={f <- @rollup_files} class="flex items-center gap-3 py-2">
              <.icon name={Attachments.file_icon(f)} class="w-5 h-5 text-base-content/60 shrink-0" />
              <a
                href={Attachments.download_url(f)}
                target="_blank"
                rel="noopener"
                class="link link-hover text-sm flex-1 min-w-0 truncate"
              >
                {f.original_file_name || f.file_name}
              </a>
              <span class="text-xs text-base-content/50 shrink-0">
                {Attachments.format_file_size(f.size)}
              </span>
            </li>
          </ul>
        </div>
      </div>

      <%!-- Core picker: uploads land in / browse is scoped to the folder.
           It owns its own upload channel and notifies results back here. --%>
      <.live_component
        module={MediaSelectorModal}
        id={"#{@id}-selector"}
        show={@show_picker}
        mode={:multiple}
        file_type_filter={if @kind == :images, do: :image, else: :all}
        browse={false}
        selected_uuids={[]}
        scope_folder_id={@folder_uuid}
        phoenix_kit_current_user={@phoenix_kit_current_user}
        notify={{__MODULE__, @id}}
      />
    </div>
    """
  end
end
