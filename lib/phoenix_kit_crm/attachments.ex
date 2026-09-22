defmodule PhoenixKitCRM.Attachments do
  @moduledoc """
  Folder-scoped media attachments for a CRM contact, backed by core
  `PhoenixKit.Modules.Storage` (the same per-resource-folder convention
  `phoenix_kit_staff`/`phoenix_kit_catalogue` use — no module-owned table, no
  migration).

  Each contact owns a deterministic root folder `crm-contact-<uuid>` for generic
  files, with a nested **`Images`** subfolder for images — all of a contact's
  files in one folder, images in a folder inside it. Folders are resolved **by
  name** on every read (never cached on `Contact`, so renaming/deleting the
  folder in `/admin/media` can't strand a dangling uuid) and created lazily on
  first upload; the core `[:name, :parent_uuid]` unique index makes
  find-or-create race-safe.

  Files live in core `phoenix_kit_files` under the folder; uploading/browsing is
  done by `MediaSelectorModal` (scoped to the folder), so this module only
  resolves folders, lists their files, (un)links picked files, and removes them
  — soft-trash a sole-owner file, unlink a shared one. It never hard-deletes a
  possibly-shared asset.

  ## Parent folder

  By default resource folders are created at the storage root. A host can
  group them under per-type containers:

      config :phoenix_kit_crm, :attachments_parent_folder, {MyApp.Media, :for_crm}

  called as `for_crm(:company | :contact | :interaction, actor_uuid, subject)`
  (or `for_crm/2` when the host doesn't need the third arg), where `subject` is
  the record's uuid, returning `{:ok, parent_folder_uuid}` or `nil` (root). The
  parent only decides where a **new** folder is created: reads, purges and the
  timeline run without an actor, so a folder is resolved by its deterministic
  name wherever it lives — under the configured parent first, then the root,
  then anywhere else (created under a parent the hook no longer returns, or
  moved in `/admin/media`). Folders that predate the setting are still found —
  no adoption, no twin ever created. Only live folders count: a folder trashed
  in `/admin/media` is never uploaded into again. The nested `Images`
  subfolder is always resolved strictly inside its record folder. The
  convention itself is core's `PhoenixKit.Modules.Storage.ResourceFolders`.

  The hook also runs on reads (every Media tab load and timeline render), so
  keep it cheap. A hook that raises or returns anything else falls back to the
  root.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder, ResourceFolders}
  alias PhoenixKit.Utils.Format

  @images_folder_name "Images"
  @interaction_prefix "crm-interaction-"
  @avatar_key "avatar_uuid"
  @avatar_pointer {:metadata, @avatar_key}
  # Inline grid is unpaginated; cap the query so a pathological folder can't
  # freeze the tab. The picker uploads ≤20/submit, so this is generous.
  @list_limit 200

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @typedoc "Which CRM record a folder belongs to."
  @type resource :: :contact | :company

  @doc "Deterministic root folder name for a record's files (`crm-<resource>-<uuid>`)."
  @spec root_folder_name(resource(), binary()) :: binary()
  def root_folder_name(resource, uuid) when resource in [:contact, :company],
    do: "crm-#{resource}-#{uuid}"

  # ── Folder resolution ──────────────────────────────────────────────

  @doc """
  Resolves the folder uuid for `kind` (`:files` → root, `:images` → the nested
  `Images` subfolder) **without creating** it. Returns the uuid or `nil` (used
  on render so viewing a tab doesn't spawn empty folders).
  """
  @spec folder_uuid(resource(), binary(), :files | :images, binary() | nil) :: binary() | nil
  def folder_uuid(resource, uuid, kind, actor_uuid \\ nil)

  def folder_uuid(resource, uuid, :files, actor_uuid),
    do: uuid_of(get_record_folder(resource, uuid, actor_uuid))

  def folder_uuid(resource, uuid, :images, actor_uuid) do
    case get_record_folder(resource, uuid, actor_uuid) do
      %Folder{uuid: root} ->
        uuid_of(
          quietly("get_folder", nil, fn ->
            ResourceFolders.find_under(@images_folder_name, root)
          end)
        )

      _ ->
        nil
    end
  end

  defp get_record_folder(resource, uuid, actor_uuid) do
    get_folder(root_folder_name(resource, uuid), parent_folder_uuid(resource, actor_uuid, uuid))
  end

  @doc """
  Find-or-create the folder for `kind`, returning `{:ok, uuid}` or
  `{:error, :folder_unavailable}`. Race-safe: a lost create (unique
  `[:name, :parent_uuid]`) re-resolves the winner. Call when an action needs
  the folder to exist (opening the picker / handling a selection).
  """
  @spec ensure_folder(resource(), binary(), :files | :images, binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def ensure_folder(resource, uuid, :files, actor_uuid) do
    ensure_record_folder(
      root_folder_name(resource, uuid),
      parent_folder_uuid(resource, actor_uuid, uuid),
      actor_uuid
    )
  end

  # "Images" is not a unique name, so it is only ever looked up inside the
  # record folder — never at the storage root, where a host's own "Images"
  # folder may live.
  def ensure_folder(resource, uuid, :images, actor_uuid) do
    with {:ok, root} <- ensure_folder(resource, uuid, :files, actor_uuid) do
      @images_folder_name |> ResourceFolders.ensure(root, actor_uuid) |> ensured()
    end
  end

  @doc false
  # Host-configured parent folder for a resource kind; `nil` = storage root
  # (the default), see moduledoc "Parent folder". The hook contract, and the
  # fallback to the root for a failing hook or a non-uuid answer, are core's
  # (`ResourceFolders.parent_uuid/4`).
  @spec parent_folder_uuid(atom(), binary() | nil, term()) :: binary() | nil
  def parent_folder_uuid(kind, actor_uuid, subject \\ nil),
    do: ResourceFolders.parent_uuid(:phoenix_kit_crm, kind, actor_uuid, subject)

  # A record folder's name embeds the record's uuid, so the folder is found
  # wherever it lives — see the moduledoc "Parent folder". Never adopts,
  # never twins.
  defp ensure_record_folder(name, parent_uuid, actor_uuid) do
    name
    |> ResourceFolders.ensure(parent_uuid, actor_uuid,
      lookup: fn -> ResourceFolders.find_named(name, parent_uuid, anywhere: true) end
    )
    |> ensured()
  end

  defp ensured({:ok, %Folder{uuid: uuid}}), do: {:ok, uuid}
  defp ensured({:error, _reason}), do: {:error, :folder_unavailable}

  # Among live same-named folders: under `parent_uuid`, then at root, then
  # elsewhere, oldest first.
  defp get_folder(name, parent_uuid) do
    quietly("get_folder #{name}", nil, fn ->
      ResourceFolders.find_named(name, parent_uuid, anywhere: true)
    end)
  end

  defp uuid_of(%Folder{uuid: uuid}), do: uuid
  defp uuid_of(_), do: nil

  # A read on a render path: a failure is logged and answers `default`.
  defp quietly(what, default, fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[CRM] #{what} failed: #{inspect(error)}")
      default
  catch
    :exit, reason ->
      Logger.warning("[CRM] #{what} failed: #{ResourceFolders.describe_failure({:exit, reason})}")
      default
  end

  # ── Listing ────────────────────────────────────────────────────────

  @doc """
  Files attached to `folder_uuid` (home-folder files plus those linked in via
  `FolderLink`), newest first, excluding trashed and system-managed ones.
  `:only` narrows by type: `:images` (file_type == "image"), `:non_images`,
  or `:all` (default). Defensive — keeps a tab showing only its own kind even
  if a stray file landed in the folder.
  """
  @spec list_files(binary() | nil, keyword()) :: [File.t()]
  def list_files(nil, _opts), do: []

  def list_files(folder_uuid, opts) do
    quietly("list_files #{folder_uuid}", [], fn ->
      ResourceFolders.list_files(folder_uuid,
        only: Keyword.get(opts, :only, :all),
        limit: @list_limit
      )
    end)
  end

  @doc "Whether the file with this uuid is an image (by Storage `file_type`)."
  @spec image?(binary()) :: boolean()
  def image?(file_uuid) do
    match?(%File{file_type: "image"}, Storage.get_file(file_uuid))
  rescue
    _ -> false
  end

  # ── Attach / detach ────────────────────────────────────────────────

  @doc """
  Ensures `file_uuid` is attached to `folder_uuid` by core's rule: a no-op if
  already there (the modal's scoped uploads land here directly); adopts an
  orphan file as home; otherwise adds a `FolderLink` so a file picked from
  elsewhere appears here without being moved from its owner. Always `:ok`; a
  failure is logged.
  """
  @spec attach(binary(), binary()) :: :ok
  def attach(file_uuid, folder_uuid) do
    case ResourceFolders.attach(file_uuid, folder_uuid) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[CRM] attach #{file_uuid} failed: #{ResourceFolders.describe_failure(reason)}"
        )

        :ok
    end
  end

  @doc """
  Removes a file from `folder_uuid` by core's rule: here only via a
  `FolderLink` → drop the link; home here and linked into another live
  folder → move it there; home here and nothing else holds it → soft-trash
  (recoverable in the media trash). Never hard-deletes a shared asset, never
  touches a file that is not here.
  """
  @spec detach(binary(), binary() | nil) :: :ok | {:error, term()}
  def detach(file_uuid, folder_uuid) do
    case ResourceFolders.detach(file_uuid, folder_uuid) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Lifecycle ──────────────────────────────────────────────────────

  @doc """
  Permanently purges a record's media — deletes every folder named after the
  record (wherever it sits, trashed or not) and its whole subtree (the nested
  `Images` folder + every file; a file another folder links survives there)
  via core's cascading `delete_folder_completely/1`. Best-effort: logs and
  returns `:ok` on any failure so it never blocks a deletion. Call only on a
  **permanent** delete (soft-trash keeps the files).
  """
  @spec purge_media(resource(), binary()) :: :ok
  def purge_media(resource, uuid),
    do: ResourceFolders.purge_named(root_folder_name(resource, uuid))

  # ── Interaction-scoped media (compose-time attachments) ────────────
  #
  # Each interaction owns a flat root folder `crm-interaction-<uuid>`. Files are
  # staged in the composer (uploaded orphan / picked) and attached here when the
  # interaction is saved. Same find-or-create / list / purge plumbing as contacts.

  @doc "Deterministic root folder name for an interaction's attachments."
  @spec interaction_folder_name(binary()) :: binary()
  def interaction_folder_name(interaction_uuid), do: @interaction_prefix <> interaction_uuid

  @doc "Resolve an interaction's attachment folder uuid (no create), or nil."
  @spec interaction_folder_uuid(binary()) :: binary() | nil
  def interaction_folder_uuid(interaction_uuid),
    do:
      uuid_of(
        get_folder(
          interaction_folder_name(interaction_uuid),
          parent_folder_uuid(:interaction, nil, interaction_uuid)
        )
      )

  @doc "Find-or-create an interaction's attachment folder."
  @spec ensure_interaction_folder(binary(), binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def ensure_interaction_folder(interaction_uuid, actor_uuid),
    do:
      ensure_record_folder(
        interaction_folder_name(interaction_uuid),
        parent_folder_uuid(:interaction, actor_uuid, interaction_uuid),
        actor_uuid
      )

  @doc "Files attached to an interaction (newest first, excluding trashed)."
  @spec list_interaction_files(binary()) :: [File.t()]
  def list_interaction_files(interaction_uuid),
    do: list_files(interaction_folder_uuid(interaction_uuid), only: :all)

  @doc """
  Files for many interactions at once → `%{interaction_uuid => [File.t()]}` (only
  interactions that have files appear), newest first. Three queries total (the
  folders, then their home and linked files); used to render the timeline
  without an N+1. Each interaction's folder is picked exactly as
  `interaction_folder_uuid/1` picks it, so the timeline and the composer agree.
  """
  @spec list_files_by_interaction([binary()]) :: %{binary() => [File.t()]}
  def list_files_by_interaction([]), do: %{}

  def list_files_by_interaction(interaction_uuids) do
    quietly("list_files_by_interaction", %{}, fn ->
      name_to_iuuid = Map.new(interaction_uuids, &{interaction_folder_name(&1), &1})
      # One subject-less hook call for the whole batch.
      parent = parent_folder_uuid(:interaction, nil)

      fuuid_to_iuuid =
        name_to_iuuid
        |> Map.keys()
        |> ResourceFolders.find_named_all(parent, anywhere: true)
        |> Map.new(fn {name, folder} -> {folder.uuid, Map.fetch!(name_to_iuuid, name)} end)

      fuuid_to_iuuid
      |> Map.keys()
      |> ResourceFolders.files_by_folder()
      |> Map.new(fn {fuuid, files} -> {Map.fetch!(fuuid_to_iuuid, fuuid), files} end)
    end)
  end

  @doc "Purge an interaction's attachment folder subtree (best-effort)."
  @spec purge_interaction_media(binary()) :: :ok
  def purge_interaction_media(interaction_uuid),
    do: ResourceFolders.purge_named(interaction_folder_name(interaction_uuid))

  @doc "Fetch a `File` struct by uuid (nil-safe), for the composer's staged list."
  @spec get_file(binary()) :: File.t() | nil
  def get_file(uuid) do
    case Storage.get_file(uuid) do
      %File{} = file -> file
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Template helpers ───────────────────────────────────────────────

  @doc "Heroicon name for a file based on its Storage type / mime (`Format.file_icon/1`)."
  @spec file_icon(map()) :: String.t()
  defdelegate file_icon(file), to: Format

  @doc "Human-readable byte count (decimal units). Nil-safe."
  @spec format_file_size(integer() | nil) :: String.t()
  def format_file_size(bytes), do: Format.bytes(bytes, base: 1000, unknown: "—")

  @doc "Public download URL for a file (nil-safe)."
  @spec download_url(map()) :: String.t() | nil
  def download_url(%File{} = file), do: safe_url(fn -> Storage.get_public_url(file) end)
  def download_url(_), do: nil

  @doc "Thumbnail URL for an image file, falling back to the original (nil-safe)."
  @spec thumb_url(map()) :: String.t() | nil
  def thumb_url(%File{} = file),
    do: safe_url(fn -> Storage.get_public_url_by_variant(file, "thumbnail") end)

  def thumb_url(_), do: nil

  defp safe_url(fun) do
    fun.()
  rescue
    _ -> nil
  end

  # ── Avatar / logo ──────────────────────────────────────────────────
  #
  # A record's avatar (contact photo / company logo) is a single image-file
  # pointer kept in its `metadata` (`"avatar_uuid"`) — no new column. The image
  # is one of the record's Images-folder files (the picker is scoped there).
  # Server-owned: written only via `set_avatar/2` / `clear_avatar/1`. Works for
  # any record with `metadata` + `status` (Contact, Company).

  @doc "The record's avatar file uuid (from metadata), or nil."
  @spec avatar_uuid(struct()) :: binary() | nil
  def avatar_uuid(%{metadata: _} = record),
    do: ResourceFolders.pointer_value(record, {:metadata, @avatar_key})

  def avatar_uuid(_), do: nil

  @doc "The record's avatar `File` struct, or nil if unset / missing / trashed."
  @spec avatar_file(struct()) :: File.t() | nil
  def avatar_file(%{metadata: _} = record) do
    ResourceFolders.pointed_file(record, {:metadata, @avatar_key})
  rescue
    _ -> nil
  end

  def avatar_file(_), do: nil

  @doc "Thumbnail URL for the record's avatar (or nil)."
  @spec avatar_url(struct()) :: String.t() | nil
  def avatar_url(record), do: record |> avatar_file() |> thumb_url()

  @doc """
  Points the record's avatar at `file_uuid` (server-owned metadata write).

  Authorizes the pointer: `file_uuid` must be an image that actually lives in (or
  is linked into) *this* record's `Images` folder — a forged event can't point
  the avatar at an arbitrary file elsewhere in storage. Refuses a trashed record
  (`{:error, :record_trashed}`) and a non-candidate file
  (`{:error, :not_record_image}`); clearing is unguarded.
  """
  @spec set_avatar(resource(), struct(), binary()) :: {:ok, struct()} | {:error, term()}
  def set_avatar(_resource, %{status: "trashed"}, file_uuid)
      when is_binary(file_uuid) and file_uuid != "",
      do: {:error, :record_trashed}

  def set_avatar(resource, %{metadata: _, uuid: record_uuid} = record, file_uuid)
      when resource in [:contact, :company] and is_binary(file_uuid) and file_uuid != "" do
    images = folder_uuid(resource, record_uuid, :images)

    # Check and write in one step (the file cannot leave the folder in
    # between), and only the avatar key is written.
    case ResourceFolders.point_at(
           record.__struct__,
           record_uuid,
           @avatar_pointer,
           file_uuid,
           images,
           only: :images
         ) do
      :ok -> with_fresh_metadata(record)
      {:error, :not_held} -> {:error, :not_record_image}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether `file_uuid` is one of the record's own `Images`-folder image files
  (home or linked, excluding trashed) — the authorization basis for `set_avatar/3`.
  """
  @spec avatar_candidate?(resource(), binary(), binary()) :: boolean()
  def avatar_candidate?(resource, record_uuid, file_uuid)
      when resource in [:contact, :company] and is_binary(file_uuid) and file_uuid != "" do
    images_folder = folder_uuid(resource, record_uuid, :images)

    quietly("avatar_candidate?", false, fn ->
      ResourceFolders.holds_file?(images_folder, file_uuid, only: :images)
    end)
  end

  def avatar_candidate?(_resource, _record_uuid, _file_uuid), do: false

  @doc "Clears the record's avatar pointer."
  @spec clear_avatar(struct()) :: {:ok, struct()} | {:error, term()}
  def clear_avatar(%{metadata: _} = record) do
    case ResourceFolders.write_pointer(record.__struct__, record.uuid, @avatar_pointer, nil) do
      :ok -> with_fresh_metadata(record)
      error -> error
    end
  end

  # The pointer is written in place, one key; hand the caller its own struct
  # (preloads and all) with the metadata as the row now holds it.
  defp with_fresh_metadata(%schema{uuid: uuid} = record) do
    case repo().one(from(r in schema, where: r.uuid == ^uuid, select: r.metadata)) do
      nil -> {:error, :not_found}
      metadata -> {:ok, %{record | metadata: metadata}}
    end
  end
end
