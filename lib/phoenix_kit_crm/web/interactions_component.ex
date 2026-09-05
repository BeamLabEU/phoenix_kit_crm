defmodule PhoenixKitCRM.Web.InteractionsComponent do
  @moduledoc """
  The Interactions / History tab for a contact OR a company: a
  reverse-chronological feed plus a composer to log a new one with a
  free-form-but-resolvable "involved parties" picker (CRM contacts + staff).

  The host passes exactly one anchor assign — `contact` (the original mode)
  or `company` (since V05). The composer stamps the anchor server-side, the
  feed loads `list_involving/1` or `list_for_company/2` accordingly, and in
  company mode an `All | Company | People` scope filter splits the company's
  own interactions from the member rollup. Delete is offered only on rows
  THIS page anchors — a row that merely spills in (a party involvement, a
  member's own interaction) is read-only here and managed from its anchor's
  page.
  """
  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  alias PhoenixKit.Utils.Date, as: DateUtils

  import PhoenixKitCRM.Web.InteractionHelpers,
    only: [party_badge: 1, format_local: 2, offset_minutes_now: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Attachments, Contacts, Interactions, Paths, StaffLink}
  alias PhoenixKitCRM.Schemas.{Company, Contact, Interaction}

  # Curated attachment allowlist — broad enough for real CRM attachments but
  # excludes inline-renderable script vectors (.html/.htm/.svg/.xml/.xhtml) that
  # could be served same-origin. Don't trust the browser-supplied content-type;
  # the extension is what core derives the stored/served mime from.
  @upload_accept ~w(
    .jpg .jpeg .png .gif .webp .bmp .tiff .heic
    .pdf .txt .csv .rtf .md
    .doc .docx .xls .xlsx .ppt .pptx .odt .ods .odp
    .zip .gz .tar
    .mp3 .wav .m4a .ogg
    .mp4 .mov .webm .mkv
  )
  # Explicit size cap (LiveView's default is only 8 MB) — 25 MiB per file.
  @max_upload_size 26_214_400

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    tz = socket.assigns[:tz] || "0"

    {:ok,
     socket
     |> assign_anchor()
     |> assign_new(:feed_scope, fn -> :all end)
     |> assign_new(:staged_parties, fn -> [] end)
     |> assign_new(:staged_files, fn -> [] end)
     # Composer fields are controlled (kept in assigns) so re-renders triggered
     # by staging a party don't wipe what the user has typed. `c_occurred_at`
     # is the user's LOCAL wall-clock time (in their profile timezone); it's
     # converted to/from UTC at the storage boundary. (The party search box +
     # dropdown are owned entirely by core's SearchPicker JS hook — no server state.)
     |> assign_new(:c_type, fn -> "note" end)
     |> assign_new(:c_subject, fn -> "" end)
     |> assign_new(:c_body, fn -> "" end)
     |> assign_new(:c_occurred_at, fn -> local_now_str(tz) end)
     |> assign_new(:save_error, fn -> nil end)
     |> assign(:staff_enabled, StaffLink.enabled?())
     |> assign(:storage_enabled, storage_enabled?())
     |> maybe_allow_upload()
     |> maybe_reload_interactions()}
  end

  # Which record this feed belongs to. Exactly one of the `contact`/`company`
  # host assigns is set; deriving kind + struct once keeps every branch below
  # a one-liner.
  defp assign_anchor(socket) do
    case socket.assigns[:company] do
      %{uuid: _} = company ->
        socket |> assign(:anchor_kind, :company) |> assign(:anchor, company)

      _ ->
        socket |> assign(:anchor_kind, :contact) |> assign(:anchor, socket.assigns.contact)
    end
  end

  # Reload the feed only when the anchor or scope filter changes (mount /
  # navigation / filter click) or the host signals a refresh via
  # `:refresh_token` (its PubSub-driven `send_update`). An unrelated host
  # re-render (e.g. the header avatar changing) re-passes the anchor struct
  # but no new token, so we skip the timeline re-query.
  defp maybe_reload_interactions(socket) do
    key = {socket.assigns.anchor.uuid, socket.assigns.feed_scope}
    token = socket.assigns[:refresh_token]

    if socket.assigns[:loaded_key] == key and socket.assigns[:loaded_token] == token do
      socket
    else
      socket
      |> load_interactions()
      |> assign(:loaded_key, key)
      |> assign(:loaded_token, token)
    end
  end

  defp load_interactions(socket) do
    interactions =
      case socket.assigns.anchor_kind do
        :contact ->
          Interactions.list_involving(socket.assigns.anchor.uuid)

        :company ->
          Interactions.list_for_company(socket.assigns.anchor.uuid,
            scope: socket.assigns.feed_scope
          )
      end

    interaction_files =
      if socket.assigns[:storage_enabled],
        do: Attachments.list_files_by_interaction(Enum.map(interactions, & &1.uuid)),
        else: %{}

    socket
    |> assign(:interactions, interactions)
    |> assign(:interaction_files, interaction_files)
  end

  defp storage_enabled? do
    Storage.enabled?()
  rescue
    _ -> false
  end

  @impl true
  # Core's SearchPicker JS hook owns the search box + dropdown entirely (instant,
  # client-side). It pushes the (client-debounced) query here; we run the DB
  # search and hand rows back to the hook via push_event. No server-side search
  # state is kept.
  def handle_event("search_party", %{"q" => q} = params, socket) when is_binary(q) do
    q = String.trim(q)

    # On a contact's page the anchor contact is already implied — keep them
    # out of the picker. A company anchor implies no person, so nothing is
    # excluded there.
    excluded =
      case socket.assigns.anchor_kind do
        :contact -> [socket.assigns.anchor.uuid]
        :company -> []
      end

    {results, has_more} =
      search_parties(q, socket.assigns.staff_enabled, parse_limit(params["limit"]), excluded)

    {:noreply,
     push_event(socket, "crm_party_results", %{q: q, results: results, has_more: has_more})}
  end

  def handle_event("stage_party", %{"kind" => kind, "uuid" => uuid, "label" => label}, socket)
      when is_binary(kind) and is_binary(uuid) and is_binary(label) do
    party = %{raw_name: label, kind: kind, contact_uuid: nil, staff_person_uuid: nil}

    party =
      case kind do
        "contact" -> %{party | contact_uuid: uuid}
        "staff" -> %{party | staff_person_uuid: uuid}
        _ -> party
      end

    {:noreply, socket |> maybe_append(party) |> push_event("crm_party_staged", %{})}
  end

  def handle_event("stage_text", %{"name" => name}, socket) when is_binary(name) do
    name = String.trim(name)
    party = %{raw_name: name, kind: "text", contact_uuid: nil, staff_person_uuid: nil}
    socket = if name == "", do: socket, else: maybe_append(socket, party)

    {:noreply, push_event(socket, "crm_party_staged", %{})}
  end

  def handle_event("add_me", _params, socket) do
    case me_party(socket.assigns[:current_user_uuid], socket.assigns[:current_user_name]) do
      nil -> {:noreply, socket}
      party -> {:noreply, maybe_append(socket, party)}
    end
  end

  def handle_event("remove_party", %{"idx" => idx}, socket) do
    case Integer.parse(to_string(idx)) do
      {i, _} ->
        {:noreply,
         assign(socket, :staged_parties, List.delete_at(socket.assigns.staged_parties, i))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("composer_change", %{"interaction" => p}, socket) when is_map(p) do
    {:noreply,
     socket
     |> assign(:c_type, p["interaction_type"] || socket.assigns.c_type)
     |> assign(:c_subject, p["subject"] || "")
     |> assign(:c_body, p["body"] || "")
     |> assign(:c_occurred_at, p["occurred_at"] || socket.assigns.c_occurred_at)
     |> assign(:save_error, nil)}
  end

  def handle_event("composer_change", _params, socket), do: {:noreply, socket}

  def handle_event("set_now", _params, socket) do
    {:noreply, assign(socket, :c_occurred_at, local_now_str(socket.assigns[:tz] || "0"))}
  end

  def handle_event("save_interaction", _params, socket) do
    # `c_occurred_at` is the user's LOCAL time (profile tz); store true UTC.
    occurred_at = local_to_utc(socket.assigns.c_occurred_at, socket.assigns[:tz] || "0")

    anchor_key =
      case socket.assigns.anchor_kind do
        :contact -> "contact_uuid"
        :company -> "company_uuid"
      end

    attrs =
      %{
        anchor_key => socket.assigns.anchor.uuid,
        "interaction_type" => socket.assigns.c_type,
        "subject" => socket.assigns.c_subject,
        "body" => socket.assigns.c_body,
        "owner_user_uuid" => socket.assigns[:current_user_uuid]
      }
      |> maybe_put_occurred_at(occurred_at)

    party_inputs =
      Enum.map(socket.assigns.staged_parties, fn p ->
        %{
          raw_name: p.raw_name,
          contact_uuid: p[:contact_uuid],
          staff_person_uuid: p[:staff_person_uuid]
        }
      end)

    file_uuids = Enum.map(socket.assigns.staged_files, & &1.uuid)

    case Interactions.create_interaction(attrs, party_inputs, file_uuids) do
      {:ok, _interaction} ->
        # (The audit-log entry, file attach, + realtime broadcast are emitted by
        # the context.) Reset the composer ONLY on success — every failure path
        # below leaves the typed fields + staged parties + files untouched.
        {:noreply,
         socket
         |> assign(:staged_parties, [])
         |> assign(:staged_files, [])
         |> assign(:c_type, "note")
         |> assign(:c_subject, "")
         |> assign(:c_body, "")
         |> assign(:c_occurred_at, local_now_str(socket.assigns[:tz] || "0"))
         |> assign(:save_error, nil)
         # A company-anchored save under the People scope would be invisible —
         # the row is excluded by construction, so the composer clears and
         # nothing appears, indistinguishable from a failed save. Jump to All
         # so the just-logged row is on screen.
         |> then(fn s ->
           if s.assigns.anchor_kind == :company and s.assigns.feed_scope == :members,
             do: assign(s, :feed_scope, :all),
             else: s
         end)
         |> load_interactions()}

      {:error, changeset} ->
        {:noreply, assign(socket, :save_error, changeset_message(changeset))}
    end
  rescue
    e ->
      Logger.error(
        "[CRM] save_interaction crashed (#{socket.assigns.anchor_kind}=#{inspect(socket.assigns.anchor.uuid)}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:noreply, assign(socket, :save_error, default_save_error())}
  end

  def handle_event("set_feed_scope", %{"scope" => scope}, socket)
      when scope in ~w(all company members) do
    {:noreply,
     socket
     |> assign(:feed_scope, String.to_existing_atom(scope))
     |> maybe_reload_interactions()}
  end

  def handle_event("delete_interaction", %{"uuid" => uuid}, socket) do
    # Two gates: the row must actually be in this feed (a forged event must
    # not delete an unrelated interaction by uuid), AND this page must be its
    # ANCHOR — a row that merely spills in (party involvement, the member
    # rollup) is managed from its own page, not deleted from someone else's.
    row = Enum.find(socket.assigns.interactions, &(&1.uuid == uuid))

    with %Interaction{} = row <- row,
         true <- owns_row?(socket, row),
         %Interaction{} = i <- Interactions.get_interaction(uuid) do
      case Interactions.delete_interaction(i, actor_uuid: socket.assigns[:current_user_uuid]) do
        {:ok, _} ->
          {:noreply, socket |> assign(:save_error, nil) |> load_interactions()}

        {:error, _changeset} ->
          # The row stays; say so instead of reloading it back in silence.
          {:noreply, assign(socket, :save_error, gettext("Could not delete this interaction."))}
      end
    else
      _ -> {:noreply, socket}
    end
  rescue
    # Two sessions deleting the same row race get/delete: the loser's
    # repo.delete raises StaleEntryError. The row is gone either way — just
    # refresh rather than crashing this LiveView into a reconnect.
    _e in Ecto.StaleEntryError -> {:noreply, load_interactions(socket)}
  end

  # The dropzone form's phx-change (auto_upload does the actual work via the
  # progress callback) — just acknowledge it.
  def handle_event("validate_attachment", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_attachment", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :attachments, ref)}

  def handle_event("remove_staged_file", %{"uuid" => uuid}, socket) do
    {:noreply,
     assign(socket, :staged_files, Enum.reject(socket.assigns.staged_files, &(&1.uuid == uuid)))}
  end

  # Ignore any unexpected/forged event rather than crashing the LiveView.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Inline upload (drag-drop / click) ──────────────────────────────
  #
  # Uploads are allowed on THIS component (like core's MediaSelectorModal), so
  # the dropzone lives inline in the composer — no modal. Each finished entry is
  # stored to a bucket (orphan, no folder), then staged; on save the staged
  # uuids are adopted into the interaction's folder.

  defp maybe_allow_upload(socket) do
    cond do
      uploads_allowed?(socket) ->
        assign(socket, :can_attach, true)

      socket.assigns.storage_enabled and Storage.list_enabled_buckets() != [] ->
        socket
        |> allow_upload(:attachments,
          accept: known_upload_accept(),
          max_entries: 10,
          max_file_size: @max_upload_size,
          auto_upload: true,
          progress: &handle_progress/3
        )
        |> assign(:can_attach, true)

      true ->
        assign(socket, :can_attach, false)
    end
  rescue
    # Degrading to no-dropzone is right (a broken upload config must not take
    # the composer down), but it has to be LOUD: a silent version of this
    # rescue hid a raising allow_upload for weeks and nobody could attach
    # anything, with no trace anywhere.
    e ->
      Logger.warning(
        "[CRM] interaction attachments disabled (allow_upload failed): " <> Exception.message(e)
      )

      assign(socket, :can_attach, false)
  end

  # `allow_upload` REFUSES any accept extension the mime library cannot name
  # (`MIME.has_type?/1`) — and one unknown extension used to cost every file
  # type its upload, because the raise landed in the rescue above (.m4a/.ogg/
  # .mkv are unknown to mime 2.0.7). Offer the locally-known subset instead;
  # a host that wants the rest extends `config :mime, :types` and they rejoin
  # by themselves.
  defp known_upload_accept do
    Enum.filter(@upload_accept, fn "." <> ext -> MIME.has_type?(ext) end)
  end

  @doc false
  # Test-only window onto the filtered accept list, so a mime-table change
  # that would make allow_upload raise fails a test instead of a page.
  @spec __known_upload_accept__() :: [String.t()]
  def __known_upload_accept__, do: known_upload_accept()

  defp upload_error_label(:too_large), do: gettext("File is larger than 25 MB")
  defp upload_error_label(:not_accepted), do: gettext("This file type is not accepted")

  defp upload_error_label(:too_many_files),
    do: gettext("Too many files — up to 10 per interaction")

  defp upload_error_label(_), do: gettext("Upload failed")

  defp uploads_allowed?(socket) do
    match?(%{attachments: _}, socket.assigns[:uploads] || %{})
  end

  defp handle_progress(:attachments, entry, socket) do
    if entry.done? do
      case consume_uploaded_entry(socket, entry, &store_upload(socket, &1.path, entry)) do
        uuid when is_binary(uuid) -> {:noreply, stage_files(socket, [uuid])}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Persist a consumed upload to a bucket (no folder yet — adopted on save).
  defp store_upload(socket, path, entry) do
    ext = entry.client_name |> Path.extname() |> String.replace_leading(".", "")
    mime = entry.client_type || MIME.from_path(entry.client_name)

    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: user_uuid} ->
        hash = Auth.calculate_file_hash(path)

        case Storage.store_file_in_buckets(
               path,
               file_type(mime),
               user_uuid,
               hash,
               ext,
               entry.client_name
             ) do
          {:ok, file, :duplicate} -> {:ok, file.uuid}
          {:ok, file} -> {:ok, file.uuid}
          _ -> {:postpone, :error}
        end

      _ ->
        {:postpone, :error}
    end
  rescue
    _ -> {:postpone, :error}
  end

  defp file_type("image/" <> _), do: "image"
  defp file_type("video/" <> _), do: "video"
  defp file_type(_), do: "other"

  # Add newly-uploaded files to the composer's staged list (deduped). The files
  # are attached to the interaction's folder when it's saved.
  defp stage_files(socket, uuids) do
    current = socket.assigns[:staged_files] || []
    seen = MapSet.new(current, & &1.uuid)

    added =
      uuids
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.map(&Attachments.get_file/1)
      |> Enum.reject(&is_nil/1)

    assign(socket, :staged_files, current ++ added)
  end

  # Best-effort, user-facing message from a failed changeset (interaction or a
  # rolled-back party); details are logged, the input is preserved either way.
  defp changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, to_string(msg), fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", safe_str(v))
      end)
    end)
    |> Enum.flat_map(fn {_field, msgs} -> msgs end)
    |> List.first()
    |> case do
      detail when is_binary(detail) -> gettext("Couldn't save: %{detail}", detail: detail)
      _ -> default_save_error()
    end
  rescue
    # Never let the error-message builder itself crash the save handler.
    _ -> default_save_error()
  end

  defp default_save_error do
    gettext("Couldn't save this interaction. Your input was kept — please try again.")
  end

  defp safe_str(v) when is_binary(v), do: v
  defp safe_str(v) when is_atom(v) or is_number(v), do: to_string(v)
  defp safe_str(v), do: inspect(v)

  defp append_party(socket, party) do
    assign(socket, :staged_parties, socket.assigns.staged_parties ++ [party])
  end

  defp maybe_append(socket, party) do
    if already_staged?(socket.assigns.staged_parties, party),
      do: socket,
      else: append_party(socket, party)
  end

  # "Add me" → the current user's linked CRM contact if any, else free text.
  # Tagged `is_me` for the "(you)" badge suffix (display-only; dropped on save).
  defp me_party(uuid, name) when is_binary(uuid) do
    base =
      case Contacts.get_by_user_uuid(uuid) do
        %Contact{} = c ->
          %{
            raw_name: Contact.display_name(c),
            kind: "contact",
            contact_uuid: c.uuid,
            staff_person_uuid: nil
          }

        _ ->
          text_party(name)
      end

    mark_me(base)
  end

  defp me_party(_uuid, name), do: mark_me(text_party(name))

  defp text_party(name) when is_binary(name) and name != "" do
    %{raw_name: name, kind: "text", contact_uuid: nil, staff_person_uuid: nil}
  end

  defp text_party(_), do: nil

  defp mark_me(nil), do: nil
  defp mark_me(party), do: Map.put(party, :is_me, true)

  defp me_staged?(parties), do: Enum.any?(parties, & &1[:is_me])

  defp already_staged?(staged, %{contact_uuid: cu}) when is_binary(cu) do
    Enum.any?(staged, &(&1[:contact_uuid] == cu))
  end

  defp already_staged?(staged, %{staff_person_uuid: su}) when is_binary(su) do
    Enum.any?(staged, &(&1[:staff_person_uuid] == su))
  end

  defp already_staged?(staged, %{raw_name: name}) do
    Enum.any?(staged, &(&1[:raw_name] == name))
  end

  # Fetch one extra per source so the hook knows whether to offer "Load more".
  defp search_parties(query, staff_enabled?, limit, exclude_uuids) do
    contacts =
      query
      |> Contacts.search_contacts(limit + 1, exclude_uuids)
      |> Enum.map(fn c ->
        %{
          kind: "contact",
          uuid: c.uuid,
          label: Contact.display_name(c),
          sublabel: c.email || "",
          icon: "hero-user"
        }
      end)

    staff = if staff_enabled?, do: staff_results(query, limit + 1), else: []
    has_more = length(contacts) > limit or length(staff) > limit

    {Enum.take(contacts, limit) ++ Enum.take(staff, limit), has_more}
  end

  defp staff_results(query, limit) do
    query
    |> StaffLink.search(limit)
    |> Enum.map(fn p ->
      %{
        kind: "staff",
        uuid: p.uuid,
        label: p.name,
        sublabel: p[:job_title] || gettext("Staff"),
        icon: "hero-identification"
      }
    end)
  end

  @default_limit 8
  @max_limit 60

  defp parse_limit(n) when is_integer(n), do: n |> max(@default_limit) |> min(@max_limit)

  defp parse_limit(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> parse_limit(i)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp maybe_put_occurred_at(attrs, nil), do: attrs
  defp maybe_put_occurred_at(attrs, %DateTime{} = dt), do: Map.put(attrs, "occurred_at", dt)

  # ── Timezone helpers (storage is always UTC; UI is in the user's profile tz) ──

  # "Now" in the user's timezone, formatted for a datetime-local input.
  # "Now" as a datetime-local value in the viewer's zone.
  defp local_now_str(tz), do: DateUtils.format_datetime_local(DateTime.utc_now(), tz)

  # A local datetime-local string (in the user's tz) → the true UTC instant,
  # resolved for the date typed (core's `parse_datetime_local/2`, per
  # instant — a named zone follows daylight saving on that date).
  defp local_to_utc(value, tz) when is_binary(value) and value != "" do
    case DateUtils.parse_datetime_local(value, tz) do
      {:ok, utc} -> utc
      _ -> nil
    end
  end

  defp local_to_utc(_, _), do: nil

  # This page anchors the row — the only rows its Delete is offered on.
  defp owns_row?(%Phoenix.LiveView.Socket{assigns: assigns}, row), do: owns_row?(assigns, row)
  defp owns_row?(%{anchor_kind: :contact, anchor: a}, row), do: row.contact_uuid == a.uuid
  defp owns_row?(%{anchor_kind: :company, anchor: a}, row), do: row.company_uuid == a.uuid

  defp composer_title(:contact, _anchor), do: gettext("Log an interaction")

  defp composer_title(:company, company),
    do: gettext("Log an interaction with %{name}", name: Company.display_name(company))

  defp feed_scopes do
    [
      {"all", gettext("All")},
      {"company", gettext("Company")},
      {"members", gettext("People")}
    ]
  end

  # Host-passed assigns (the anchor this feed belongs to — `contact` OR
  # `company`, exactly one — + the acting user's context, threaded from the
  # show LiveView). Declared so the call site is checked and the contract is
  # explicit.
  attr(:contact, :map, default: nil)
  attr(:company, :map, default: nil)
  attr(:current_user_uuid, :string, default: nil)
  attr(:current_user_name, :string, default: nil)
  attr(:phoenix_kit_current_user, :map, default: nil)
  attr(:tz, :string, default: "0")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-6">
      <%!-- Composer --%>
      <div class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body gap-3">
          <h3 class="font-semibold">{composer_title(@anchor_kind, @anchor)}</h3>

          <.form
            for={%{}}
            as={:interaction}
            phx-change="composer_change"
            phx-target={@myself}
            class="flex flex-col gap-3"
          >
            <.select
              id="crm-type"
              name="interaction[interaction_type]"
              value={@c_type}
              label={gettext("Type")}
              options={Enum.map(Interaction.types(), &{Interaction.type_label(&1), &1})}
            />

            <div>
              <.input
                type="datetime-local"
                id="crm-when"
                name="interaction[occurred_at]"
                value={@c_occurred_at}
                label={gettext("When")}
                phx-hook="CrmWhenWarnings"
                data-profile-offset-minutes={offset_minutes_now(@tz)}
                data-profile-zone={PhoenixKit.Settings.get_timezone_label(@tz)}
                data-warning-target="crm-when-warning"
                data-setnow-target="crm-set-now"
              />
              <div class="flex flex-wrap items-center gap-2 mt-1">
                <div
                  id="crm-when-warning"
                  data-when-warning
                  phx-update="ignore"
                  class="text-xs text-warning empty:hidden flex flex-col gap-0.5"
                >
                </div>
                <button
                  type="button"
                  id="crm-set-now"
                  phx-update="ignore"
                  phx-click="set_now"
                  phx-target={@myself}
                  class="btn btn-xs btn-outline gap-1 hidden"
                >
                  <.icon name="hero-clock" class="w-3.5 h-3.5" /> {gettext("Set to now")}
                </button>
              </div>
            </div>

            <.input
              id="crm-subject"
              name="interaction[subject]"
              value={@c_subject}
              label={gettext("Subject")}
              placeholder={gettext("Optional")}
            />
            <.textarea
              id="crm-body"
              name="interaction[body]"
              value={@c_body}
              label={gettext("What was discussed?")}
            />
          </.form>

          <%!-- Attachments — real inline drag-drop / click dropzone (uploads
                like core's media picker); staged files attach on save. --%>
          <div :if={@can_attach} class="flex flex-col gap-2">
            <form phx-change="validate_attachment" phx-target={@myself} id={"crm-attach-#{@id}"}>
              <div
                phx-drop-target={@uploads.attachments.ref}
                class="rounded-box border-2 border-dashed border-base-300 text-base-content/60 hover:border-primary hover:text-base-content hover:bg-base-200/40 transition"
              >
                <label
                  for={@uploads.attachments.ref}
                  class="flex flex-col items-center justify-center gap-1 w-full py-5 px-3 cursor-pointer"
                >
                  <.icon name="hero-arrow-up-tray" class="w-5 h-5" />
                  <span class="text-sm font-medium">{gettext("Drag files here or click to upload")}</span>
                  <span class="text-xs text-base-content/50">{gettext("Files or images")}</span>
                </label>
                <.live_file_input upload={@uploads.attachments} class="hidden" />
              </div>
            </form>

            <%!-- In-progress uploads. With auto_upload a REJECTED entry
                 (too large, wrong type, 11th file) never reaches the progress
                 callback — it just sits here; without the error line it reads
                 as a frozen upload with no explanation. --%>
            <div
              :for={entry <- @uploads.attachments.entries}
              class="flex items-center gap-2 text-xs"
            >
              <span class="flex-1 truncate">{entry.client_name}</span>
              <span
                :for={err <- upload_errors(@uploads.attachments, entry)}
                class="text-error shrink-0"
              >
                {upload_error_label(err)}
              </span>
              <progress
                :if={upload_errors(@uploads.attachments, entry) == []}
                value={entry.progress}
                max="100"
                class="progress progress-primary progress-xs w-24"
              >
                {entry.progress}%
              </progress>
              <button
                type="button"
                phx-click="cancel_attachment"
                phx-value-ref={entry.ref}
                phx-target={@myself}
                aria-label={gettext("Cancel")}
                class="text-error"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <div :for={err <- upload_errors(@uploads.attachments)} class="text-xs text-error">
              {upload_error_label(err)}
            </div>

            <%!-- Staged (uploaded, pending save) --%>
            <div :if={@staged_files != []} class="flex flex-wrap gap-2">
              <span :for={f <- @staged_files} class="badge badge-lg gap-1">
                <.icon name={Attachments.file_icon(f)} class="w-3.5 h-3.5 shrink-0" />
                <span class="max-w-[12rem] truncate">{f.original_file_name || f.file_name}</span>
                <button
                  type="button"
                  phx-click="remove_staged_file"
                  phx-value-uuid={f.uuid}
                  phx-target={@myself}
                  aria-label={gettext("Remove")}
                  class="ml-1 cursor-pointer"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </span>
            </div>
          </div>

          <%!-- Involved parties — outside the <.form> so Enter in the search box
                never submits the composer (it only stages parties). --%>
          <div class="flex flex-col gap-2">
              <div class="flex items-center justify-between gap-2">
                <div class="flex items-center gap-1">
                  <label for="crm-party-search" class="fieldset-legend font-semibold leading-none">
                    {gettext("Involved parties")}
                  </label>
                  <div class="relative inline-flex items-center group">
                    <.icon
                      name="hero-information-circle"
                      class="w-3.5 h-3.5 text-base-content/40 group-hover:text-base-content cursor-help"
                    />
                    <div class="hidden group-hover:block absolute left-0 top-6 z-30 w-56 p-3 rounded-box border border-base-200 bg-base-100 shadow-lg text-xs space-y-1.5">
                      <div class="font-semibold text-base-content">{gettext("In search results:")}</div>
                      <div class="flex items-center gap-2 text-base-content/70">
                        <.icon name="hero-user" class="w-4 h-4 text-base-content/50" />
                        <span>{gettext("CRM contact")}</span>
                      </div>
                      <div :if={@staff_enabled} class="flex items-center gap-2 text-base-content/70">
                        <.icon name="hero-identification" class="w-4 h-4 text-base-content/50" />
                        <span>{gettext("Staff member")}</span>
                      </div>
                      <div class="flex items-center gap-2 text-base-content/70">
                        <.icon name="hero-plus-mini" class="w-4 h-4 text-base-content/50" />
                        <span>{gettext("Added as free text")}</span>
                      </div>
                    </div>
                  </div>
                </div>
                <button
                  :if={@current_user_uuid && not me_staged?(@staged_parties)}
                  type="button"
                  phx-click="add_me"
                  phx-target={@myself}
                  class="btn btn-xs btn-outline gap-1"
                >
                  <.icon name="hero-user-plus" class="w-3.5 h-3.5" /> {gettext("Add me")}
                </button>
              </div>

              <div :if={@staged_parties != []} class="flex flex-wrap gap-2">
                <span :for={{p, idx} <- Enum.with_index(@staged_parties)} class="badge badge-lg gap-1">
                  {p.raw_name}<span :if={p[:is_me]} class="opacity-60">&nbsp;{gettext("(you)")}</span>
                  <button
                    type="button"
                    phx-click="remove_party"
                    phx-value-idx={idx}
                    phx-target={@myself}
                    aria-label={gettext("Remove")}
                    class="ml-1 cursor-pointer"
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </span>
              </div>

              <%!-- Core SearchPicker: the dropdown is rendered + toggled
                    entirely client-side (instant); the server (search_party)
                    only returns rows via push_event. --%>
              <.search_picker
                id="crm-party-search"
                dropdown_id="crm-party-dropdown"
                search_event="search_party"
                results_event="crm_party_results"
                pick_event="stage_party"
                text_event="stage_text"
                staged_event="crm_party_staged"
                searching_label={gettext("Searching…")}
                add_prefix_label={gettext("Add")}
                add_suffix_label={gettext("as free text")}
                adding_label={gettext("Adding…")}
                more_label={gettext("Load more")}
                loading_more_label={gettext("Loading…")}
                placeholder={gettext("Type a name — searches contacts%{staff}…", staff: if(@staff_enabled, do: gettext(" and staff"), else: ""))}
              />
            </div>

          <div :if={@save_error} class="alert alert-error text-sm py-2" role="alert">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
            <span>{@save_error}</span>
          </div>

          <div class="flex justify-end">
            <.button
              type="button"
              phx-click="save_interaction"
              phx-target={@myself}
              class="btn-primary btn-sm"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save interaction")}
            </.button>
          </div>
        </div>
      </div>

      <%!-- Scope filter (company mode): the company's own interactions vs the
           member rollup. Segmented buttons, not counted index tabs — the feed
           is one query and this is a view split, not navigation. --%>
      <div :if={@anchor_kind == :company} class="flex items-center gap-1">
        <button
          :for={{scope, label} <- feed_scopes()}
          type="button"
          phx-click="set_feed_scope"
          phx-value-scope={scope}
          phx-target={@myself}
          class={["btn btn-xs", (to_string(@feed_scope) == scope && "btn-primary") || "btn-ghost"]}
        >
          {label}
        </button>
      </div>

      <%!-- Timeline --%>
      <.empty_state
        :if={@interactions == []}
        icon="hero-chat-bubble-left-right"
        title={gettext("No interactions logged yet.")}
      />

      <ol :if={@interactions != []} class="flex flex-col gap-3">
        <li :for={i <- @interactions} class="card bg-base-100 shadow-sm border border-base-200">
          <div class="card-body py-3 gap-1">
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="badge badge-ghost badge-sm">{Interaction.type_label(i.interaction_type)}</span>
                <%!-- Provenance: on a company page every row says whether it is
                     the company's own or a member's; on a contact page a
                     company-anchored row (here via party involvement) names
                     the company it belongs to. --%>
                <span
                  :if={@anchor_kind == :company && i.company_uuid}
                  class="badge badge-outline badge-sm gap-1"
                >
                  <.icon name="hero-building-office-2" class="w-3 h-3" /> {gettext("Company")}
                </span>
                <.link
                  :if={@anchor_kind == :company && i.contact}
                  navigate={Paths.contact(i.contact.uuid)}
                  class="link link-hover text-sm font-medium"
                >
                  {Contact.display_name(i.contact)}
                </.link>
                <.link
                  :if={@anchor_kind == :contact && match?(%{uuid: _}, i.company)}
                  navigate={Paths.company(i.company.uuid)}
                  class="link link-hover text-sm text-base-content/70 inline-flex items-center gap-1"
                >
                  <.icon name="hero-building-office-2" class="w-3 h-3" /> {Company.display_name(
                    i.company
                  )}
                </.link>
                <span class="text-xs text-base-content/60">{format_local(i.occurred_at, @tz)}</span>
              </div>
              <button
                :if={owns_row?(assigns, i)}
                type="button"
                phx-click="delete_interaction"
                phx-value-uuid={i.uuid}
                phx-target={@myself}
                phx-disable-with={gettext("Deleting…")}
                data-confirm={gettext("Delete this interaction?")}
                class="btn btn-ghost btn-xs text-error"
              >
                <.icon name="hero-trash-mini" class="w-3 h-3" />
              </button>
            </div>
            <div :if={i.subject} class="font-medium">{i.subject}</div>
            <div :if={i.body} class="text-sm whitespace-pre-wrap">{i.body}</div>
            <div :if={i.parties != []} class="flex flex-wrap gap-1 mt-1">
              <span class="text-xs text-base-content/50">{gettext("Involved:")}</span>
              <.party_badge :for={p <- i.parties} party={p} />
            </div>

            <% files = Map.get(@interaction_files, i.uuid, []) %>
            <div :if={files != []} class="flex flex-wrap gap-2 mt-1">
              <a
                :for={f <- files}
                href={Attachments.download_url(f)}
                target="_blank"
                rel="noopener"
                class="inline-flex items-center gap-1 badge badge-ghost badge-sm hover:badge-outline"
                title={f.original_file_name || f.file_name}
              >
                <.icon name={Attachments.file_icon(f)} class="w-3.5 h-3.5 shrink-0" />
                <span class="max-w-[10rem] truncate">{f.original_file_name || f.file_name}</span>
              </a>
            </div>
          </div>
        </li>
      </ol>
    </div>
    """
  end
end
