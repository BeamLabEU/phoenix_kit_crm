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
  no adoption, no twin ever created. The nested `Images` subfolder is always
  resolved strictly inside its record folder.

  The hook also runs on reads (every Media tab load and timeline render), so
  keep it cheap. A hook that raises or returns anything else falls back to the
  root.
  """

  require Logger

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}

  @images_folder_name "Images"
  @interaction_prefix "crm-interaction-"
  @avatar_key "avatar_uuid"
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
      %Folder{uuid: root} -> uuid_of(get_folder_under(@images_folder_name, root))
      _ -> nil
    end
  end

  defp get_record_folder(resource, uuid, actor_uuid) do
    get_folder(root_folder_name(resource, uuid), parent_folder_uuid(resource, actor_uuid, uuid))
  end

  @doc """
  Find-or-create the folder for `kind`, returning `{:ok, uuid}` or
  `{:error, reason}`. Race-safe: a lost create (unique `[:name, :parent_uuid]`)
  re-resolves the winner. Call when an action needs the folder to exist (opening
  the picker / handling a selection).
  """
  @spec ensure_folder(resource(), binary(), :files | :images, binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def ensure_folder(resource, uuid, :files, actor_uuid) do
    find_or_create(
      root_folder_name(resource, uuid),
      parent_folder_uuid(resource, actor_uuid, uuid),
      actor_uuid,
      &get_folder/2
    )
  end

  # "Images" is not a unique name, so it is only ever looked up inside the
  # record folder — never at the storage root, where a host's own "Images"
  # folder may live.
  def ensure_folder(resource, uuid, :images, actor_uuid) do
    with {:ok, root} <- ensure_folder(resource, uuid, :files, actor_uuid) do
      find_or_create(@images_folder_name, root, actor_uuid, &get_folder_under/2)
    end
  end

  @doc false
  # Host-configured parent folder for a resource kind; `nil` = storage root
  # (the default), see moduledoc "Parent folder". Calls the configured
  # `{mod, fun}` as `fun(kind, actor_uuid, subject)` when it accepts 3 args,
  # else `fun(kind, actor_uuid)`.
  @spec parent_folder_uuid(atom(), binary() | nil, term()) :: binary() | nil
  def parent_folder_uuid(kind, actor_uuid, subject \\ nil) do
    case Application.get_env(:phoenix_kit_crm, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        call_parent_hook(mod, fun, kind, actor_uuid, subject)

      _ ->
        nil
    end
  rescue
    error ->
      Logger.warning("[CRM] parent folder hook failed for #{inspect(kind)}: #{inspect(error)}")
      nil
  end

  defp call_parent_hook(mod, fun, kind, actor_uuid, subject) do
    case invoke_parent_hook(mod, fun, kind, actor_uuid, subject) do
      {:ok, uuid} when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  defp invoke_parent_hook(mod, fun, kind, actor_uuid, subject) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        apply(mod, fun, [kind, actor_uuid, subject])

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        apply(mod, fun, [kind, actor_uuid])

      true ->
        nil
    end
  end

  # `lookup` is `&get_folder/2` for the deterministic record folders and
  # `&get_folder_under/2` for a subfolder whose name is only unique locally.
  defp find_or_create(name, parent_uuid, user_uuid, lookup) do
    case lookup.(name, parent_uuid) do
      %Folder{uuid: uuid} -> {:ok, uuid}
      nil -> create_or_resolve(name, parent_uuid, user_uuid, lookup)
    end
  rescue
    error ->
      Logger.warning("[CRM] ensure_folder #{name} failed: #{inspect(error)}")
      {:error, :folder_unavailable}
  end

  defp create_or_resolve(name, parent_uuid, user_uuid, lookup) do
    case Storage.create_folder(%{name: name, parent_uuid: parent_uuid, user_uuid: user_uuid}) do
      {:ok, %Folder{uuid: uuid}} ->
        {:ok, uuid}

      # Lost the create race against a concurrent first-upload — the unique
      # [:name, :parent_uuid] constraint rejected us; re-resolve the winner.
      {:error, %Ecto.Changeset{}} ->
        case lookup.(name, parent_uuid) do
          %Folder{uuid: uuid} -> {:ok, uuid}
          _ -> {:error, :folder_unavailable}
        end
    end
  end

  # A record folder by its deterministic name, wherever it lives — see the
  # moduledoc "Parent folder". Never adopts, never twins.
  defp get_folder(name, parent_uuid) do
    from(f in Folder, where: f.name == ^name, limit: 1)
    |> prefer_parent(parent_uuid)
    |> repo().one()
  rescue
    error ->
      Logger.warning("[CRM] get_folder #{name} failed: #{inspect(error)}")
      nil
  end

  # Among same-named folders: under `parent_uuid`, then at root, then oldest.
  defp prefer_parent(query, nil),
    do: order_by(query, [f], desc: is_nil(f.parent_uuid), asc: f.inserted_at)

  defp prefer_parent(query, parent_uuid) do
    order_by(query, [f],
      desc: coalesce(f.parent_uuid == ^parent_uuid, false),
      desc: is_nil(f.parent_uuid),
      asc: f.inserted_at
    )
  end

  defp get_folder_under(name, nil) do
    from(f in Folder, where: f.name == ^name and is_nil(f.parent_uuid), limit: 1) |> repo().one()
  rescue
    error ->
      Logger.warning("[CRM] get_folder #{name} failed: #{inspect(error)}")
      nil
  end

  defp get_folder_under(name, parent_uuid) do
    from(f in Folder, where: f.name == ^name and f.parent_uuid == ^parent_uuid, limit: 1)
    |> repo().one()
  rescue
    error ->
      Logger.warning("[CRM] get_folder #{name} failed: #{inspect(error)}")
      nil
  end

  defp uuid_of(%Folder{uuid: uuid}), do: uuid
  defp uuid_of(_), do: nil

  # ── Listing ────────────────────────────────────────────────────────

  @doc """
  Files attached to `folder_uuid` (home-folder files plus those linked in via
  `FolderLink`), newest first, excluding trashed. `:only` narrows by type:
  `:images` (file_type == "image"), `:non_images`, or `:all` (default).
  Defensive — keeps a tab showing only its own kind even if a stray file landed
  in the folder.
  """
  @spec list_files(binary() | nil, keyword()) :: [File.t()]
  def list_files(nil, _opts), do: []

  def list_files(folder_uuid, opts) do
    linked = from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

    base =
      from(f in File,
        where:
          (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked)) and f.status != "trashed",
        order_by: [desc: f.inserted_at],
        limit: @list_limit
      )

    query =
      case Keyword.get(opts, :only, :all) do
        :images -> where(base, [f], f.file_type == "image")
        :non_images -> where(base, [f], f.file_type != "image")
        _ -> base
      end

    repo().all(query)
  rescue
    error ->
      Logger.warning("[CRM] list_files #{folder_uuid} failed: #{inspect(error)}")
      []
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
  Ensures `file_uuid` is attached to `folder_uuid`: a no-op if already home
  there (the modal's scoped uploads land here directly); adopts an orphan file
  as home; otherwise adds a `FolderLink` so a file picked from elsewhere appears
  here without being moved from its owner.
  """
  @spec attach(binary(), binary()) :: :ok
  def attach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil ->
        :ok

      %File{folder_uuid: ^folder_uuid} ->
        :ok

      %File{folder_uuid: nil} = file ->
        file |> Ecto.Changeset.change(%{folder_uuid: folder_uuid}) |> repo().update()
        :ok

      %File{} ->
        %FolderLink{}
        |> FolderLink.changeset(%{folder_uuid: folder_uuid, file_uuid: file_uuid})
        |> repo().insert(on_conflict: :nothing, conflict_target: [:folder_uuid, :file_uuid])

        :ok
    end
  rescue
    error ->
      Logger.warning("[CRM] attach #{file_uuid} failed: #{inspect(error)}")
      :ok
  end

  @doc """
  Removes a file from `folder_uuid`. Home here and not linked elsewhere →
  soft-trash (recoverable in the media trash). Home here but also linked
  elsewhere → promote a link to home. Here only via a `FolderLink` → drop the
  link. Never hard-deletes a shared asset.
  """
  @spec detach(binary(), binary() | nil) :: :ok | {:error, term()}
  def detach(_file_uuid, nil), do: :ok

  def detach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil -> :ok
      %File{folder_uuid: ^folder_uuid} = file -> detach_home(file)
      %File{} -> detach_link(file_uuid, folder_uuid)
    end
  rescue
    error ->
      Logger.warning("[CRM] detach #{file_uuid} failed: #{inspect(error)}")
      {:error, error}
  end

  defp detach_home(file) do
    case list_links(file.uuid) do
      [] ->
        case soft_trash(file) do
          {:ok, _} -> :ok
          err -> err
        end

      [%FolderLink{} = link | _] ->
        repo().transaction(fn ->
          file |> Ecto.Changeset.change(%{folder_uuid: link.folder_uuid}) |> repo().update!()
          repo().delete!(link)
        end)
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  defp detach_link(file_uuid, folder_uuid) do
    from(fl in FolderLink, where: fl.file_uuid == ^file_uuid and fl.folder_uuid == ^folder_uuid)
    |> repo().delete_all()

    :ok
  end

  defp soft_trash(%File{} = file) do
    file
    |> Ecto.Changeset.change(%{
      status: "trashed",
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> repo().update()
  end

  defp list_links(file_uuid) do
    from(fl in FolderLink, where: fl.file_uuid == ^file_uuid) |> repo().all()
  end

  # ── Lifecycle ──────────────────────────────────────────────────────

  @doc """
  Permanently purges a record's media — deletes the root folder and its whole
  subtree (the nested `Images` folder + every file) via core's cascading
  `delete_folder_completely/1`. Best-effort: logs and returns `:ok` on any
  failure so it never blocks a deletion. Call only on a **permanent** delete
  (soft-trash keeps the files).
  """
  @spec purge_media(resource(), binary()) :: :ok
  def purge_media(resource, uuid),
    do: purge_folder(root_folder_name(resource, uuid), parent_folder_uuid(resource, nil, uuid))

  defp purge_folder(name, parent_uuid) do
    case get_folder(name, parent_uuid) do
      %Folder{} = folder ->
        Storage.delete_folder_completely(folder)
        :ok

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("[CRM] purge folder #{name} failed: #{inspect(error)}")
      :ok
  end

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
      find_or_create(
        interaction_folder_name(interaction_uuid),
        parent_folder_uuid(:interaction, actor_uuid, interaction_uuid),
        actor_uuid,
        &get_folder/2
      )

  @doc "Files attached to an interaction (newest first, excluding trashed)."
  @spec list_interaction_files(binary()) :: [File.t()]
  def list_interaction_files(interaction_uuid),
    do: list_files(interaction_folder_uuid(interaction_uuid), only: :all)

  @doc """
  Files for many interactions at once → `%{interaction_uuid => [File.t()]}` (only
  interactions that have files appear). Two queries total (folders, then files);
  used to render the timeline without an N+1. Compose-time uploads land home in
  the interaction folder, so home-folder files are sufficient (no FolderLinks).
  """
  @spec list_files_by_interaction([binary()]) :: %{binary() => [File.t()]}
  def list_files_by_interaction([]), do: %{}

  def list_files_by_interaction(interaction_uuids) do
    name_to_iuuid = Map.new(interaction_uuids, &{interaction_folder_name(&1), &1})
    names = Map.keys(name_to_iuuid)
    # One subject-less hook call for the whole batch.
    parent = parent_folder_uuid(:interaction, nil)

    # One folder per interaction (DISTINCT ON name), picked exactly as
    # get_folder/2 picks it, so the timeline and the composer agree.
    fuuid_to_iuuid =
      from(f in Folder, where: f.name in ^names, distinct: f.name, select: {f.uuid, f.name})
      |> prefer_parent(parent)
      |> repo().all()
      |> Map.new(fn {fuuid, name} -> {fuuid, Map.get(name_to_iuuid, name)} end)

    case Map.keys(fuuid_to_iuuid) do
      [] -> %{}
      fuuids -> group_interaction_files(fuuids, fuuid_to_iuuid)
    end
  rescue
    error ->
      Logger.warning("[CRM] list_files_by_interaction failed: #{inspect(error)}")
      %{}
  end

  # Home files (folder_uuid = the interaction folder) PLUS files linked in via a
  # FolderLink (identical-bytes uploads dedup to a link, not a copy), each mapped
  # back to its interaction.
  defp group_interaction_files(fuuids, fuuid_to_iuuid) do
    home =
      from(f in File,
        where: f.folder_uuid in ^fuuids and f.status != "trashed",
        order_by: [desc: f.inserted_at]
      )
      |> repo().all()
      |> Enum.map(&{Map.get(fuuid_to_iuuid, &1.folder_uuid), &1})

    links =
      from(fl in FolderLink,
        where: fl.folder_uuid in ^fuuids,
        select: {fl.folder_uuid, fl.file_uuid}
      )
      |> repo().all()

    (home ++ linked_file_pairs(links, fuuid_to_iuuid))
    |> Enum.group_by(fn {iuuid, _f} -> iuuid end, fn {_iuuid, f} -> f end)
  end

  defp linked_file_pairs([], _fuuid_to_iuuid), do: []

  defp linked_file_pairs(links, fuuid_to_iuuid) do
    files =
      from(f in File, where: f.uuid in ^Enum.map(links, &elem(&1, 1)) and f.status != "trashed")
      |> repo().all()
      |> Map.new(&{&1.uuid, &1})

    links
    |> Enum.map(fn {fuuid, fid} -> {Map.get(fuuid_to_iuuid, fuuid), Map.get(files, fid)} end)
    |> Enum.reject(fn {_iuuid, f} -> is_nil(f) end)
  end

  @doc "Purge an interaction's attachment folder subtree (best-effort)."
  @spec purge_interaction_media(binary()) :: :ok
  def purge_interaction_media(interaction_uuid),
    do:
      purge_folder(
        interaction_folder_name(interaction_uuid),
        parent_folder_uuid(:interaction, nil, interaction_uuid)
      )

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

  @doc "Heroicon name for a file based on its Storage type / mime."
  @spec file_icon(map()) :: String.t()
  def file_icon(%{file_type: "image"}), do: "hero-photo"
  def file_icon(%{file_type: "video"}), do: "hero-film"
  def file_icon(%{file_type: "audio"}), do: "hero-musical-note"
  def file_icon(%{file_type: "archive"}), do: "hero-archive-box"
  def file_icon(%{mime_type: "application/pdf"}), do: "hero-document-text"
  def file_icon(_), do: "hero-document"

  @doc "Human-readable byte count. Nil-safe."
  @spec format_file_size(integer() | nil) :: String.t()
  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_file_size(_), do: "—"

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
  def avatar_uuid(%{metadata: m}) when is_map(m) do
    case Map.get(m, @avatar_key) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  def avatar_uuid(_), do: nil

  @doc "The record's avatar `File` struct, or nil if unset / missing / trashed."
  @spec avatar_file(struct()) :: File.t() | nil
  def avatar_file(record) do
    case avatar_uuid(record) do
      nil ->
        nil

      uuid ->
        case Storage.get_file(uuid) do
          %File{status: "trashed"} -> nil
          %File{} = file -> file
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

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
    if avatar_candidate?(resource, record_uuid, file_uuid) do
      put_metadata(record, @avatar_key, file_uuid)
    else
      {:error, :not_record_image}
    end
  end

  @doc """
  Whether `file_uuid` is one of the record's own `Images`-folder image files
  (home or linked, excluding trashed) — the authorization basis for `set_avatar/3`.
  """
  @spec avatar_candidate?(resource(), binary(), binary()) :: boolean()
  def avatar_candidate?(resource, record_uuid, file_uuid)
      when resource in [:contact, :company] and is_binary(file_uuid) and file_uuid != "" do
    case folder_uuid(resource, record_uuid, :images) do
      nil ->
        false

      images_folder ->
        Enum.any?(list_files(images_folder, only: :images), &(&1.uuid == file_uuid))
    end
  end

  def avatar_candidate?(_resource, _record_uuid, _file_uuid), do: false

  @doc "Clears the record's avatar pointer."
  @spec clear_avatar(struct()) :: {:ok, struct()} | {:error, term()}
  def clear_avatar(%{metadata: _} = record), do: put_metadata(record, @avatar_key, nil)

  defp put_metadata(record, key, value) do
    metadata = record.metadata || %{}

    metadata =
      if is_nil(value), do: Map.delete(metadata, key), else: Map.put(metadata, key, value)

    record |> Ecto.Changeset.change(metadata: metadata) |> repo().update()
  end
end
