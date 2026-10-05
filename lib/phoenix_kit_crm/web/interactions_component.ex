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

  ## Project mode (V8)

  With a `project_uuid` the component is the projects hub's Client tab: the
  feed is the PROJECT's interactions (`Interactions.list_for_project/2`),
  the composer defaults to a meeting and gains a duration, a billable
  switch and minutes per attendee from our side (the staged staff people
  and "me"); each of those becomes an entry in the project's work ledger
  through `ProjectsLink` (actor = the attendee, the author in
  `metadata.entered_by_uuid`). A row then shows its length, the time it
  logged, and — through core's mention index — the tasks whose
  description points at it, plus "Add task" to make one with the `#` chip
  already in place (`host_paths["new_task"]`, handed in by the hub).
  `can_write: false` (the hub's verdict on the viewer) hides every write.
  """
  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  alias PhoenixKit.Utils.Date, as: DateUtils

  import PhoenixKitCRM.Web.InteractionHelpers,
    only: [party_badge: 1, format_local: 2, offset_minutes_now: 1]

  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKit.ResourceLinks
  alias PhoenixKitCRM.{Attachments, Contacts, InteractionLinks, Interactions, Paths}
  alias PhoenixKitCRM.{ProjectsLink, StaffLink}
  alias PhoenixKitCRM.Schemas.{Company, Contact, Interaction}
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Attachments, as: CoreAttachments

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
     |> assign(:project_mode, is_binary(socket.assigns[:project_uuid]))
     |> assign_new(:c_type, fn a -> if a[:project_uuid], do: "meeting", else: "note" end)
     |> assign_new(:c_duration, fn -> "" end)
     |> assign_new(:c_billable, fn -> false end)
     |> assign_new(:attendee_minutes, fn -> %{} end)
     # The row being edited in the composer (nil = composing a new one).
     |> assign_new(:editing_uuid, fn -> nil end)
     |> assign_new(:edit_logged, fn -> %{} end)
     # Project mode: the planned event this interaction is the record of,
     # and the project's events to pick it from.
     |> assign_new(:c_event_uuid, fn -> "" end)
     |> assign_planned_events()
     # Planning a meeting (project mode): the small form's state.
     |> assign_new(:planning, fn -> false end)
     |> assign_new(:p_title, fn -> "" end)
     |> assign_new(:p_when, fn -> "" end)
     |> assign_new(:p_location, fn -> "" end)
     |> assign_new(:plan_error, fn -> nil end)
     |> assign_new(:c_subject, fn -> "" end)
     |> assign_new(:c_body, fn -> "" end)
     |> assign_new(:c_occurred_at, fn -> local_now_str(tz) end)
     |> assign_new(:save_error, fn -> nil end)
     # An upload that could not be stored, said by the dropzone until the
     # next upload succeeds or the interaction is saved — typing must not
     # hide it while no file is staged.
     |> assign_new(:upload_error, fn -> nil end)
     |> assign(:staff_enabled, StaffLink.enabled?())
     |> assign(:storage_enabled, storage_enabled?())
     |> assign_new(:show_feed, fn -> true end)
     |> assign_new(:show_composer, fn -> true end)
     |> maybe_allow_upload()
     |> maybe_reload_interactions()
     |> apply_opening()}
  end

  # The drawer instance's opening request — an edit, or a plan to be the
  # record of — applied once, after the interactions are loaded.
  defp apply_opening(%{assigns: %{opening_applied: true}} = socket), do: socket

  defp apply_opening(socket) do
    socket = assign(socket, :opening_applied, true)

    cond do
      is_binary(socket.assigns[:open_editing_uuid]) ->
        load_for_edit(socket, socket.assigns.open_editing_uuid)

      is_binary(socket.assigns[:open_plan_uuid]) ->
        socket |> assign(:c_type, "meeting") |> pick_event(socket.assigns.open_plan_uuid)

      true ->
        socket
    end
  end

  # Whether this instance owns the composer, or must ask the tab to open
  # its drawer (`{:crm_client, :compose, opts}`).
  defp composes_here?(socket), do: socket.assigns[:show_composer] != false

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
    key = {socket.assigns.anchor.uuid, socket.assigns.feed_scope, socket.assigns[:project_uuid]}
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
      case {socket.assigns[:project_uuid], socket.assigns.anchor_kind} do
        {project_uuid, _} when is_binary(project_uuid) ->
          Interactions.list_for_project(project_uuid, limit: 100)

        {_, :contact} ->
          Interactions.list_involving(socket.assigns.anchor.uuid)

        {_, :company} ->
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
    |> assign(:interaction_links, backlinks_for(socket, interactions))
  end

  # What points at each row — the tasks whose description carries this
  # interaction's `#` chip. Core keeps the reverse index; its resolver
  # turns each source into a title and a path, batched per type. Project
  # mode only: on a contact or company page the question is not asked.
  defp backlinks_for(%{assigns: %{project_mode: true}}, interactions) do
    sources =
      interactions
      |> Enum.flat_map(fn i ->
        InteractionLinks.type()
        |> Mentions.list_backlinks(i.uuid, limit: 20)
        |> Enum.map(&{i.uuid, &1.source_type, &1.source_uuid})
      end)
      |> Enum.uniq()

    context =
      sources
      |> Enum.map(fn {_i, type, uuid} -> %{resource_type: type, resource_uuid: uuid} end)
      |> ResourceLinks.resolve()

    sources
    |> Enum.reduce(%{}, fn {interaction_uuid, type, uuid}, acc ->
      case ResourceLinks.info_for(context, type, uuid) do
        %{title: title} = info ->
          link = %{title: title, url: ResourceLinks.url(info)}
          Map.update(acc, interaction_uuid, [link], &(&1 ++ [link]))

        _ ->
          acc
      end
    end)
  rescue
    e ->
      Logger.warning("[CRM] backlinks failed: #{Exception.message(e)}")
      %{}
  end

  defp backlinks_for(_socket, _interactions), do: %{}

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

    results = with_me_row(results, q, socket.assigns)

    {:noreply,
     push_event(socket, "crm_party_results", %{q: q, results: results, has_more: has_more})}
  end

  # The viewer picked themselves from the search — the same party "Add me"
  # stages, so their time is theirs (not a staff row's) and the badge shows.
  def handle_event("stage_party", %{"kind" => "me"}, socket) do
    socket = stage_me(socket)
    {:noreply, push_event(socket, "crm_party_staged", %{})}
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
    {:noreply, stage_me(socket)}
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

  def handle_event("composer_change", %{"interaction" => p} = params, socket) when is_map(p) do
    {:noreply,
     socket
     |> assign(:c_type, p["interaction_type"] || socket.assigns.c_type)
     |> assign(:c_subject, p["subject"] || "")
     |> assign(:c_body, p["body"] || "")
     |> assign(:c_occurred_at, p["occurred_at"] || socket.assigns.c_occurred_at)
     |> assign_project_fields(p, params)
     |> assign(:save_error, nil)}
  end

  def handle_event("composer_change", _params, socket), do: {:noreply, socket}

  # Edit: the row's fields and parties go into the composer; files and the
  # time already logged are left alone (the ledger is append-only). Save
  # then updates the row instead of creating one.
  def handle_event("edit_interaction", %{"uuid" => uuid}, socket) do
    if composes_here?(socket) do
      {:noreply, load_for_edit(socket, uuid)}
    else
      send(self(), {:crm_client, :compose, editing_uuid: uuid})
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    if socket.assigns[:show_feed] == false, do: send(self(), {:crm_client, :cancel})
    {:noreply, reset_composer(socket)}
  end

  def handle_event("unlink_plan", _params, socket),
    do: {:noreply, assign(socket, :c_event_uuid, "")}

  # ── Planning a meeting (project mode) ─────────────────────────────

  def handle_event("start_planning", _params, socket) do
    tz = socket.assigns[:tz] || "0"
    company = socket.assigns.anchor

    {:noreply,
     socket
     |> assign(:planning, true)
     |> assign(:p_title, gettext("Meeting with %{name}", name: Company.display_name(company)))
     |> assign(
       :p_when,
       DateUtils.format_datetime_local(DateTime.add(DateTime.utc_now(), 86_400), tz)
     )
     |> assign(:p_location, "")
     |> assign(:plan_error, nil)}
  end

  def handle_event("cancel_planning", _params, socket),
    do: {:noreply, assign(socket, :planning, false)}

  def handle_event("plan_change", %{"plan" => p}, socket) do
    {:noreply,
     socket
     |> assign(:p_title, p["title"] || socket.assigns.p_title)
     |> assign(:p_when, p["when"] || socket.assigns.p_when)
     |> assign(:p_location, p["location"] || "")
     |> assign(:plan_error, nil)}
  end

  def handle_event("save_plan", _params, socket) do
    tz = socket.assigns[:tz] || "0"

    with starts_at when is_struct(starts_at, DateTime) <- local_to_utc(socket.assigns.p_when, tz),
         title when title != "" <- String.trim(socket.assigns.p_title),
         {:ok, _event} <-
           ProjectsLink.create_event(
             socket.assigns.project_uuid,
             %{
               title: title,
               starts_at: starts_at,
               ends_at: nil,
               all_day: false,
               location: blank_to_nil(socket.assigns.p_location)
             },
             actor_uuid: socket.assigns[:current_user_uuid]
           ) do
      {:noreply,
       socket
       |> assign(:planning, false)
       |> assign(
         :planned_events,
         ProjectsLink.list_events(socket.assigns.project_uuid, limit: 50)
       )}
    else
      "" -> {:noreply, assign(socket, :plan_error, gettext("Give the meeting a title."))}
      :error -> {:noreply, assign(socket, :plan_error, gettext("The time could not be read."))}
      nil -> {:noreply, assign(socket, :plan_error, gettext("Pick when the meeting is."))}
      _ -> {:noreply, assign(socket, :plan_error, default_save_error())}
    end
  end

  # "Log what happened" on a planned meeting: the composer opens with the
  # plan picked (its when and title prefilled), as a meeting.
  def handle_event("log_planned", %{"uuid" => uuid}, socket) do
    if composes_here?(socket) do
      {:noreply, socket |> reset_composer() |> assign(:c_type, "meeting") |> pick_event(uuid)}
    else
      send(self(), {:crm_client, :compose, plan_uuid: uuid})
      {:noreply, socket}
    end
  end

  def handle_event("set_now", _params, socket) do
    {:noreply, assign(socket, :c_occurred_at, local_now_str(socket.assigns[:tz] || "0"))}
  end

  def handle_event("save_interaction", _params, socket) do
    # `c_occurred_at` is the user's LOCAL time (profile tz); store true UTC.
    case local_to_utc(socket.assigns.c_occurred_at, socket.assigns[:tz] || "0") do
      # A typed value that cannot be read must not become "now" behind the
      # user's back: a browser without a real datetime-local widget sends
      # free text, and the schema's default would silently stamp the save.
      :error ->
        {:noreply, assign(socket, :save_error, gettext("The time could not be read."))}

      occurred_at ->
        if socket.assigns.editing_uuid,
          do: update_interaction(socket, occurred_at),
          else: save_interaction(socket, occurred_at)
    end
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

  defp save_interaction(socket, occurred_at) do
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
      |> maybe_put_occurred_at(occurred_at, socket.assigns[:tz] || "0")
      |> put_project_attrs(socket)

    party_inputs = party_inputs(socket)
    file_uuids = Enum.map(socket.assigns.staged_files, & &1.uuid)

    case Interactions.create_interaction(attrs, party_inputs, file_uuids) do
      {:ok, interaction} -> {:noreply, socket |> after_save(interaction) |> done()}
      {:error, changeset} -> {:noreply, assign(socket, :save_error, changeset_message(changeset))}
    end
  rescue
    e ->
      Logger.error(
        "[CRM] save_interaction crashed (#{socket.assigns.anchor_kind}=#{inspect(socket.assigns.anchor.uuid)}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      {:noreply, assign(socket, :save_error, default_save_error())}
  end

  # (The audit-log entry, file attach, + realtime broadcast are emitted by
  # the context.) Reset the composer ONLY on success — every failure path
  # leaves the typed fields + staged parties + files untouched. In project
  # mode the attendees' time goes to the ledger first, so its verdict is
  # the one `save_error` shows.
  defp after_save(socket, interaction) do
    socket
    |> log_attendee_time(interaction)
    |> reset_composer(keep_error: true)
    # A company-anchored save under the People scope would be invisible —
    # the row is excluded by construction, so the composer clears and
    # nothing appears, indistinguishable from a failed save. Jump to All
    # so the just-logged row is on screen.
    |> then(fn s ->
      if s.assigns.anchor_kind == :company and s.assigns.feed_scope == :members,
        do: assign(s, :feed_scope, :all),
        else: s
    end)
    |> load_interactions()
  end

  defp update_interaction(socket, occurred_at) do
    uuid = socket.assigns.editing_uuid

    with %Interaction{} = i <- Enum.find(socket.assigns.interactions, &(&1.uuid == uuid)),
         attrs =
           %{
             "interaction_type" => socket.assigns.c_type,
             "subject" => socket.assigns.c_subject,
             "body" => socket.assigns.c_body
           }
           |> maybe_put_occurred_at(occurred_at, socket.assigns[:tz] || "0")
           |> put_duration(socket),
         {:ok, updated} <-
           Interactions.update_interaction(i, attrs, party_inputs(socket),
             actor_uuid: socket.assigns[:current_user_uuid]
           ) do
      {:noreply,
       socket
       |> log_attendee_time(updated)
       |> reset_composer(keep_error: true)
       |> load_interactions()
       |> done()}
    else
      {:error, changeset} -> {:noreply, assign(socket, :save_error, changeset_message(changeset))}
      _ -> {:noreply, assign(socket, :save_error, default_save_error())}
    end
  end

  # The staged chips as the context's party inputs (the `is_me` tag and
  # `kind` are the composer's own and stay here).
  defp party_inputs(socket) do
    Enum.map(socket.assigns.staged_parties, fn p ->
      %{
        raw_name: p.raw_name,
        contact_uuid: p[:contact_uuid],
        staff_person_uuid: p[:staff_person_uuid]
      }
    end)
  end

  defp put_duration(attrs, %{assigns: %{project_mode: true} = assigns}) do
    attrs
    |> Map.put("duration_minutes", parse_minutes(assigns.c_duration))
    |> Map.put("metadata", event_metadata(existing_metadata(assigns), assigns.c_event_uuid))
  end

  defp put_duration(attrs, _socket), do: attrs

  defp existing_metadata(%{editing_uuid: uuid, interactions: rows}) do
    case Enum.find(rows, &(&1.uuid == uuid)) do
      %Interaction{metadata: m} when is_map(m) -> m
      _ -> %{}
    end
  end

  # The plan → record link lives on the interaction's metadata; "" unlinks.
  defp event_metadata(existing, uuid) when is_binary(uuid) and uuid != "",
    do: Map.put(existing, "event_uuid", uuid)

  defp event_metadata(existing, _), do: Map.delete(existing, "event_uuid")

  defp planned_label(%Interaction{metadata: %{"event_uuid" => uuid}}, assigns)
       when is_binary(uuid) do
    case Enum.find(assigns.planned_events, &(&1.uuid == uuid)) ||
           ProjectsLink.get_event(assigns.project_uuid, uuid) do
      %{starts_at: starts_at} ->
        gettext("Planned %{when}", when: format_local(starts_at, assigns.tz))

      _ ->
        nil
    end
  end

  defp planned_label(_interaction, _assigns), do: nil

  defp load_for_edit(socket, uuid) do
    case Enum.find(socket.assigns.interactions, &(&1.uuid == uuid)) do
      %Interaction{} = i ->
        tz = socket.assigns[:tz] || "0"

        socket
        |> assign(:editing_uuid, i.uuid)
        |> assign(:c_type, i.interaction_type)
        |> assign(:c_subject, i.subject || "")
        |> assign(:c_body, i.body || "")
        |> assign(:c_occurred_at, DateUtils.format_datetime_local(i.occurred_at, tz))
        |> assign(
          :c_duration,
          if(i.duration_minutes, do: Integer.to_string(i.duration_minutes), else: "")
        )
        |> assign(:c_event_uuid, (i.metadata || %{})["event_uuid"] || "")
        |> assign(:staged_parties, saved_parties(socket.assigns, i.uuid))
        |> assign_logged_time(i)
        |> assign(:save_error, nil)

      _ ->
        socket
    end
  end

  # What the ledger already holds for the row, by attendee key (the entry:
  # uuid, minutes, billable), so the edit shows each attendee's figure and
  # can amend it; the billable flag follows the entries already made.
  defp assign_logged_time(%{assigns: %{project_mode: true} = assigns} = socket, interaction) do
    entries = ProjectsLink.list_time(assigns.project_uuid, interaction.uuid)

    logged =
      Map.new(entries, fn e ->
        key =
          if e.actor_kind == "user" and e.actor_uuid == assigns[:current_user_uuid],
            do: "me",
            else: "#{e.actor_kind}:#{e.actor_uuid}"

        {key, e}
      end)

    socket
    |> assign(:edit_logged, logged)
    |> assign(:c_billable, Enum.any?(entries, & &1.billable))
  end

  defp assign_logged_time(socket, _interaction), do: assign(socket, :edit_logged, %{})

  # The drawer instance is done: the tab closes it and refreshes the feed.
  defp done(socket) do
    if socket.assigns[:show_feed] == false, do: send(self(), {:crm_client, :saved})
    socket
  end

  # Back to an empty composer for a new interaction. `keep_error: true`
  # leaves the ledger's verdict (set by `log_attendee_time/2`) in place.
  defp reset_composer(socket, opts \\ []) do
    socket
    |> assign(:editing_uuid, nil)
    |> assign(:staged_parties, [])
    |> assign(:staged_files, [])
    |> assign(:c_type, if(socket.assigns.project_mode, do: "meeting", else: "note"))
    |> assign(:c_subject, "")
    |> assign(:c_body, "")
    |> assign(:c_duration, "")
    |> assign(:c_billable, false)
    |> assign(:attendee_minutes, %{})
    |> assign(:edit_logged, %{})
    |> assign(:c_event_uuid, "")
    |> assign(:c_occurred_at, local_now_str(socket.assigns[:tz] || "0"))
    |> assign(:upload_error, nil)
    |> then(
      &if(Keyword.get(opts, :keep_error, false), do: &1, else: assign(&1, :save_error, nil))
    )
  end

  # ── Project mode: duration, attendees' time, the ledger ──────────────

  # The composer's project fields, from the change event: the length in
  # minutes, billable, and a minutes override per attendee (keyed as
  # `attendee_key/1` keys them in the markup). Only read in project mode.
  defp assign_project_fields(%{assigns: %{project_mode: true}} = socket, p, params) do
    socket
    |> assign(:c_duration, p["duration_minutes"] || socket.assigns.c_duration)
    |> assign(:c_billable, p["billable"] in ["true", "on"])
    |> assign(:attendee_minutes, Map.get(params, "attendee_minutes", %{}))
  end

  defp assign_project_fields(socket, _p, _params), do: socket

  # Picking a planned event prefills the when and the subject from the
  # plan (a person can still change both); clearing it leaves the fields.
  defp pick_event(socket, uuid) when is_binary(uuid) and uuid != "" do
    if uuid == socket.assigns.c_event_uuid do
      socket
    else
      case Enum.find(socket.assigns.planned_events, &(&1.uuid == uuid)) do
        nil -> assign(socket, :c_event_uuid, "")
        event -> apply_planned_event(socket, event)
      end
    end
  end

  defp pick_event(socket, _), do: assign(socket, :c_event_uuid, "")

  defp apply_planned_event(socket, event) do
    tz = socket.assigns[:tz] || "0"

    socket
    |> assign(:c_event_uuid, event.uuid)
    |> assign(:c_occurred_at, DateUtils.format_datetime_local(event.starts_at, tz))
    |> then(fn s ->
      if s.assigns.c_subject == "", do: assign(s, :c_subject, event.title), else: s
    end)
  end

  defp assign_planned_events(%{assigns: %{project_uuid: uuid}} = socket) when is_binary(uuid) do
    assign_new(socket, :planned_events, fn -> ProjectsLink.list_events(uuid, limit: 50) end)
  end

  defp assign_planned_events(socket), do: assign_new(socket, :planned_events, fn -> [] end)

  defp blank_to_nil(v) when is_binary(v),
    do: if(String.trim(v) == "", do: nil, else: String.trim(v))

  defp blank_to_nil(_), do: nil

  # Planned meetings no interaction is the record of yet, soonest first —
  # what the tab lists above the composer with "Log what happened".
  defp unlogged_events(assigns) do
    logged =
      assigns.interactions
      |> Enum.map(&get_in(&1.metadata || %{}, ["event_uuid"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    assigns.planned_events
    |> Enum.reject(&MapSet.member?(logged, &1.uuid))
    |> Enum.sort_by(& &1.starts_at, {:asc, DateTime})
  end

  defp put_project_attrs(attrs, %{assigns: %{project_mode: true} = assigns}) do
    attrs
    |> Map.put("project_uuid", assigns.project_uuid)
    |> Map.put("duration_minutes", parse_minutes(assigns.c_duration))
    |> Map.put("metadata", event_metadata(%{}, assigns.c_event_uuid))
  end

  defp put_project_attrs(attrs, _socket), do: attrs

  # Staged parties from OUR side — the ones whose time is the project's to
  # record: a staff person, or the viewer ("Add me"). Client contacts and
  # free-text names are attendees, not time.
  defp attendees(%Phoenix.LiveView.Socket{assigns: assigns}), do: attendees(assigns)

  # Editing: the chips are the row's saved parties (loaded by
  # `load_for_edit/2`, the viewer recognised by their contact, staff record
  # or name) plus whatever was added since; an attendee whose time is in
  # the ledger carries that entry under `:logged`.
  defp attendees(%{project_mode: true, editing_uuid: uuid} = assigns) when is_binary(uuid) do
    logged = assigns[:edit_logged] || %{}

    assigns
    |> Map.put(:editing_uuid, nil)
    |> attendees()
    |> Enum.map(&Map.put(&1, :logged, Map.get(logged, &1.key)))
  end

  defp attendees(%{project_mode: true} = assigns) do
    assigns.staged_parties
    |> Enum.with_index()
    |> Enum.flat_map(fn {party, idx} ->
      cond do
        party[:is_me] == true and is_binary(assigns[:current_user_uuid]) ->
          [
            %{
              key: "me",
              idx: idx,
              name: party.raw_name,
              actor_kind: "user",
              actor_uuid: assigns.current_user_uuid
            }
          ]

        is_binary(party[:staff_person_uuid]) ->
          [
            %{
              key: "staff:#{party.staff_person_uuid}",
              idx: idx,
              name: party.raw_name,
              actor_kind: "staff_person",
              actor_uuid: party.staff_person_uuid
            }
          ]

        true ->
          []
      end
    end)
  end

  defp attendees(_assigns), do: []

  defp saved_parties(assigns, uuid) do
    me = me_party(assigns[:current_user_uuid], assigns[:current_user_name])

    case Enum.find(assigns.interactions, &(&1.uuid == uuid)) do
      %Interaction{parties: parties} when is_list(parties) ->
        Enum.map(parties, &saved_party(&1, me, assigns[:current_user_name]))

      _ ->
        []
    end
  end

  defp saved_party(p, me, name) do
    base = %{
      raw_name: p.raw_name,
      contact_uuid: p.contact_uuid,
      staff_person_uuid: p.staff_person_uuid
    }

    if viewer?(base, me, name), do: mark_me(base), else: base
  end

  # An attendee's minutes: their own figure when typed, the meeting's length
  # when the box is blank, and no entry at all when they typed 0.
  defp attendee_minutes(assigns, %{key: key}) do
    typed = Map.get(assigns.attendee_minutes, key)

    if zero?(typed), do: nil, else: parse_minutes(typed) || parse_minutes(assigns.c_duration)
  end

  # What an edit does to an attendee's EXISTING entry: nothing when the box
  # is blank or still shows the logged figure, `:remove` on 0, `{:set, n}`
  # on a new figure.
  defp amendment(assigns, %{key: key, logged: %{minutes: minutes}}) do
    typed = Map.get(assigns.attendee_minutes, key)

    cond do
      zero?(typed) -> :remove
      parse_minutes(typed) in [nil, minutes] -> :keep
      true -> {:set, parse_minutes(typed)}
    end
  end

  defp zero?(typed), do: is_binary(typed) and String.trim(typed) == "0"

  defp parse_minutes(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_minutes(n) when is_integer(n) and n > 0, do: n
  defp parse_minutes(_), do: nil

  # One ledger entry per attendee with minutes, on the project, dated to the
  # meeting (`started_at` = when it began, `ended_at` = that plus their
  # minutes), the subject as the note, the author named in the metadata
  # next to the interaction. The interaction is already saved: a ledger
  # failure is said, never lets the meeting vanish, and never writes a
  # second time — the entries are the ledger's, appended once.
  defp log_attendee_time(%{assigns: %{project_mode: true}} = socket, interaction) do
    assigns = socket.assigns

    {logged, new} = socket |> attendees() |> Enum.split_with(&match?(%{logged: %{}}, &1))

    amendments =
      logged
      |> Enum.map(fn attendee -> {attendee, amendment(assigns, attendee)} end)
      |> Enum.reject(fn {_attendee, verdict} -> verdict == :keep end)
      |> Enum.map(fn
        {%{logged: %{uuid: uuid}}, :remove} ->
          ProjectsLink.delete_time(uuid, actor_uuid: assigns[:current_user_uuid])

        {%{logged: %{uuid: uuid}}, {:set, minutes}} ->
          ProjectsLink.update_time(uuid, minutes,
            billable: assigns.c_billable,
            actor_uuid: assigns[:current_user_uuid]
          )
      end)

    results =
      new
      |> Enum.map(fn attendee -> {attendee, attendee_minutes(assigns, attendee)} end)
      |> Enum.reject(fn {_attendee, minutes} -> is_nil(minutes) end)
      |> Enum.map(fn {attendee, minutes} ->
        ProjectsLink.log_time(assigns.project_uuid, minutes,
          assignment_uuid: nil,
          note: time_note(interaction),
          billable: assigns.c_billable,
          actor_kind: attendee.actor_kind,
          actor_uuid: attendee.actor_uuid,
          source: "manual",
          started_at: interaction.occurred_at,
          ended_at:
            interaction.occurred_at && DateTime.add(interaction.occurred_at, minutes * 60),
          metadata: %{
            "interaction_uuid" => interaction.uuid,
            "entered_by_uuid" => assigns[:current_user_uuid],
            "attendee" => attendee.name,
            "via" => "crm"
          }
        )
      end)

    failed = Enum.count(amendments ++ results, &(not match?({:ok, _}, &1)))

    if failed > 0 do
      Logger.warning("[CRM] #{failed} attendee time entries not written for #{interaction.uuid}")

      assign(
        socket,
        :save_error,
        gettext(
          "The meeting was saved, but %{count} time entries could not be written to the project.",
          count: failed
        )
      )
    else
      assign(socket, :save_error, nil)
    end
  end

  defp log_attendee_time(socket, _interaction), do: assign(socket, :save_error, nil)

  defp time_note(%Interaction{subject: subject}) when is_binary(subject) and subject != "",
    do: subject

  defp time_note(%Interaction{interaction_type: type}), do: Interaction.type_label(type)

  # The `#` chip a task's description carries to say "from this meeting",
  # and the host's add-task page with it pre-filled. Nil when the hub did
  # not hand over its path or the label cannot form a token.
  defp add_task_url(%{host_paths: %{"new_task" => path}}, %Interaction{} = i)
       when is_binary(path) do
    case Token.to_string(:resource, InteractionLinks.type(), i.uuid, InteractionLinks.label(i)) do
      {:ok, token} -> path <> "?" <> URI.encode_query(%{"description" => token})
      :error -> nil
    end
  end

  defp add_task_url(_assigns, _interaction), do: nil

  # The row on its anchor's page in the CRM, interactions tab.
  defp crm_path(%Interaction{company_uuid: uuid}) when is_binary(uuid),
    do: Paths.company(uuid) <> "?tab=interactions"

  defp crm_path(%Interaction{contact_uuid: uuid}) when is_binary(uuid),
    do: Paths.contact(uuid) <> "?tab=interactions"

  defp crm_path(_), do: Paths.index()

  defp format_minutes(nil), do: nil
  defp format_minutes(m) when m < 60, do: gettext("%{count}m", count: m)
  defp format_minutes(m) when rem(m, 60) == 0, do: gettext("%{count}h", count: div(m, 60))

  defp format_minutes(m),
    do: gettext("%{hours}h %{minutes}m", hours: div(m, 60), minutes: rem(m, 60))

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
        |> CoreAttachments.allow(:attachments, &handle_progress/3,
          accept: known_upload_accept(),
          max_entries: 10,
          max_file_size: @max_upload_size
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

  defp handle_progress(:attachments, %{done?: false}, socket), do: {:noreply, socket}

  # Stored with no folder (core's `PhoenixKitWeb.Attachments.store/4`), then
  # staged; the interaction's folder adopts it on save. A failed store is
  # consumed and said, not left behind as an entry frozen at 100%.
  defp handle_progress(:attachments, entry, socket) do
    case consume_uploaded_entry(socket, entry, &{:ok, store_upload(socket, &1.path, entry)}) do
      {:ok, file} ->
        {:noreply, socket |> stage_files([file.uuid]) |> assign(:upload_error, nil)}

      {:error, reason} ->
        Logger.warning(
          "[CRM] interaction attachment upload failed: " <>
            ResourceFolders.describe_failure(reason)
        )

        {:noreply,
         assign(socket, :upload_error, CoreAttachments.failed_message(entry.client_name, reason))}
    end
  end

  defp store_upload(socket, path, entry),
    do: CoreAttachments.store(path, entry, Actor.uuid(socket), nil)

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

  defp stage_me(socket) do
    case me_party(socket.assigns[:current_user_uuid], socket.assigns[:current_user_name]) do
      nil -> socket
      party -> maybe_append(socket, party)
    end
  end

  # "Add me" → the current user's linked CRM contact if any, else their staff
  # record, else free text. Tagged `is_me` for the "(you)" badge suffix
  # (display-only; dropped on save) and for the attendee time entry.
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
          case StaffLink.person_for_user(uuid) do
            %{uuid: staff_uuid, name: staff_name} ->
              %{
                raw_name: staff_name || name,
                kind: "staff",
                contact_uuid: nil,
                staff_person_uuid: staff_uuid
              }

            _ ->
              text_party(name)
          end
      end

    mark_me(base)
  end

  defp me_party(_uuid, name), do: mark_me(text_party(name))

  # A row for the viewer at the top of the search when the query is part of
  # their name (as the account or their contact/staff record spells it),
  # unless they are staged already. The row stands in for their contact or
  # staff result, which is always dropped, so picking them goes through
  # `me_party` and their time is logged as theirs.
  defp with_me_row(results, q, assigns) do
    case me_party(assigns[:current_user_uuid], assigns[:current_user_name]) do
      nil ->
        results

      me ->
        rest = Enum.reject(results, &same_person?(&1, me))

        if me_staged?(assigns.staged_parties) or
             not me_matches?(me, q, assigns[:current_user_name]) do
          rest
        else
          row = %{
            kind: "me",
            uuid: "me",
            label: me.raw_name,
            sublabel: gettext("(you)"),
            icon: "hero-user-circle"
          }

          [row | rest]
        end
    end
  end

  defp me_matches?(me, q, account_name) do
    down = String.downcase(q)

    down != "" and
      Enum.any?([me.raw_name, account_name], fn
        name when is_binary(name) -> String.contains?(String.downcase(name), down)
        _ -> false
      end)
  end

  # A saved party is the viewer when it is their contact, their staff
  # record, or (free text, the old way) their name.
  defp viewer?(_party, nil, _name), do: false

  defp viewer?(%{contact_uuid: c}, %{contact_uuid: c}, _name) when is_binary(c), do: true

  defp viewer?(%{staff_person_uuid: su}, %{staff_person_uuid: su}, _name) when is_binary(su),
    do: true

  defp viewer?(%{contact_uuid: nil, staff_person_uuid: nil, raw_name: raw}, me, name)
       when is_binary(raw),
       do: raw in [me.raw_name, name]

  defp viewer?(_party, _me, _name), do: false

  defp same_person?(%{kind: "contact", uuid: uuid}, %{contact_uuid: uuid}), do: true
  defp same_person?(%{kind: "staff", uuid: uuid}, %{staff_person_uuid: uuid}), do: true
  defp same_person?(_, _), do: false

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

  # The instant AND the zone it was typed in: a row can be re-resolved on
  # its own later, whatever the profile or the site setting becomes. A blank
  # When leaves the instant to the schema's default ("now") — in the same
  # zone, which is stamped either way.
  defp maybe_put_occurred_at(attrs, nil, tz), do: Map.put(attrs, "time_zone", tz)

  defp maybe_put_occurred_at(attrs, %DateTime{} = dt, tz),
    do: attrs |> Map.put("occurred_at", dt) |> Map.put("time_zone", tz)

  # ── Timezone helpers (storage is always UTC; UI is in the user's profile tz) ──

  # The zone id the browser hook may resolve dates in: anything that is not
  # a legacy numeric offset. An id the browser does not know falls back to
  # the offset-now minutes there.
  defp zone_id(tz) when is_binary(tz) do
    if Regex.match?(~r/^[+-]?\d+(\.\d+)?$/, tz), do: "", else: tz
  end

  defp zone_id(_tz), do: ""

  # "Now" as a datetime-local value in the viewer's zone.
  defp local_now_str(tz), do: DateUtils.format_datetime_local(DateTime.utc_now(), tz)

  # A local datetime-local string (in the user's tz) → the true UTC instant,
  # resolved for the date typed (core's `parse_datetime_local/2`, per
  # instant — a named zone follows daylight saving on that date). Blank
  # means "let the schema default to now"; unreadable is `:error`.
  defp local_to_utc(value, tz) when is_binary(value) and value != "" do
    case DateUtils.parse_datetime_local(value, tz) do
      {:ok, utc} -> utc
      _ -> :error
    end
  end

  defp local_to_utc(_, _), do: nil

  # This page anchors the row — the only rows its Delete is offered on.
  defp owns_row?(%Phoenix.LiveView.Socket{assigns: assigns}, row), do: owns_row?(assigns, row)
  defp owns_row?(%{anchor_kind: :contact, anchor: a}, row), do: row.contact_uuid == a.uuid
  defp owns_row?(%{anchor_kind: :company, anchor: a}, row), do: row.company_uuid == a.uuid

  defp composer_title(%{editing_uuid: uuid}) when is_binary(uuid), do: gettext("Edit interaction")

  defp composer_title(%{anchor_kind: :contact}), do: gettext("Log an interaction")

  defp composer_title(%{anchor_kind: :company, anchor: company}),
    do: gettext("Log an interaction with %{name}", name: Company.display_name(company))

  # The box of an attendee whose time is logged starts at that figure.
  defp logged_value(%{logged: %{minutes: minutes}}), do: Integer.to_string(minutes)
  defp logged_value(_attendee), do: ""

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
  # Project mode (the hub's Client tab): the project the feed and the
  # composer belong to, the hub's paths, and its verdict on writes.
  attr(:project_uuid, :string, default: nil)
  attr(:host_paths, :map, default: %{})
  attr(:can_write, :boolean, default: true)
  attr(:refresh_token, :any, default: nil)
  # The hub's Client tab splits this component in two instances: the feed
  # (with the planned ones) inline, the composer in a drawer the tab owns;
  # the feed asks the tab to open the drawer, the composer tells it when
  # it is done. `open_editing_uuid` / `open_plan_uuid` are what the drawer
  # instance applies once on mount.
  attr(:show_feed, :boolean, default: true)
  attr(:show_composer, :boolean, default: true)
  attr(:open_editing_uuid, :string, default: nil)
  attr(:open_plan_uuid, :string, default: nil)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-6">
      <%!-- Project mode: the plan. Meetings still to come (or past and not
           logged) with "Log what happened", and a small form that makes a
           project event — the plan the record later points at. --%>
      <div :if={@project_mode and @can_write and @show_feed} class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body gap-3 py-4">
          <div class="flex items-center justify-between gap-2">
            <h3 class="font-semibold">{gettext("Planned")}</h3>
            <.button :if={not @planning} type="button" phx-click="start_planning" phx-target={@myself} class="btn-outline btn-sm">
              <.icon name="hero-calendar-days" class="w-4 h-4" /> {gettext("Plan ahead")}
            </.button>
          </div>
          <% unlogged = unlogged_events(assigns) %>
          <p :if={unlogged == [] and not @planning} class="text-sm text-base-content/60">
            {gettext("Nothing planned that is not logged yet.")}
          </p>
          <ul :if={unlogged != []} class="flex flex-col divide-y divide-base-200">
            <li :for={e <- unlogged} class="py-2 flex flex-wrap items-center justify-between gap-2 text-sm">
              <span class="flex items-center gap-2 min-w-0">
                <.icon name="hero-calendar" class="w-4 h-4 text-base-content/50 shrink-0" />
                <span class="font-medium">{format_local(e.starts_at, @tz)}</span>
                <span class="truncate">{e.title}</span>
                <span :if={e.location} class="text-base-content/60 truncate">· {e.location}</span>
                <span :if={DateTime.compare(e.starts_at, DateTime.utc_now()) == :gt} class="badge badge-ghost badge-xs">
                  {gettext("upcoming")}
                </span>
              </span>
              <.button type="button" phx-click="log_planned" phx-value-uuid={e.uuid} phx-target={@myself} class="btn-ghost btn-xs">
                <.icon name="hero-pencil-square" class="w-3.5 h-3.5" /> {gettext("Log what happened")}
              </.button>
            </li>
          </ul>
          <.form :if={@planning} for={%{}} as={:plan} id={"#{@id}-plan"} phx-change="plan_change" phx-submit="save_plan" phx-target={@myself} class="flex flex-col gap-3 rounded-box border border-base-200 p-3">
            <.input id="crm-plan-title" name="plan[title]" value={@p_title} label={gettext("Title")} class="input-sm" required />
            <div class="flex flex-wrap items-end gap-3">
              <.input id="crm-plan-when" type="datetime-local" name="plan[when]" value={@p_when} label={gettext("When")} class="input-sm" wrapper_class="w-56" required />
              <.input id="crm-plan-location" name="plan[location]" value={@p_location} label={gettext("Where (optional)")} class="input-sm" wrapper_class="flex-1 min-w-48" />
            </div>
            <p class="text-xs text-base-content/60">{gettext("A meeting, a call, a visit — whatever is planned with the client. No end time: nobody knows how long it will take. It goes on the project's calendar; afterwards, \"Log what happened\" opens the composer with it.")}</p>
            <div :if={@plan_error} class="alert alert-error text-sm py-2" role="alert">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
              <span>{@plan_error}</span>
            </div>
            <div class="flex justify-end gap-2">
              <.button type="button" phx-click="cancel_planning" phx-target={@myself} class="btn-ghost btn-sm">{gettext("Cancel")}</.button>
              <.button type="submit" class="btn-primary btn-sm" phx-disable-with={gettext("Saving…")}>{gettext("Plan it")}</.button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Composer (hidden for a viewer the hub says may not write) --%>
      <div :if={@can_write and @show_composer} class="card bg-base-100 shadow-sm border border-base-200">
        <div class="card-body gap-3">
          <h3 class="font-semibold">{composer_title(assigns)}</h3>

          <.form
            for={%{}}
            as={:interaction}
            id={"#{@id}-composer"}
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
                data-editing={if(@editing_uuid, do: "true", else: "false")}
                data-profile-offset-minutes={offset_minutes_now(@tz)}
                data-profile-zone={PhoenixKit.Settings.get_timezone_label(@tz)}
                data-profile-zone-id={zone_id(@tz)}
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

            <%!-- Project mode: how long it took, and whose time it was. The
                 attendees are the staged parties from our side (staff, "me");
                 each gets the meeting's length unless a figure is typed. --%>
            <div :if={@project_mode} class="flex flex-col gap-2 rounded-box border border-base-200 p-3">
              <% plan = Enum.find(@planned_events, &(&1.uuid == @c_event_uuid)) %>
              <div :if={plan} class="flex items-center gap-2 text-sm">
                <.icon name="hero-calendar" class="w-4 h-4 text-base-content/50" />
                <span>{gettext("The record of: %{plan}", plan: "#{format_local(plan.starts_at, @tz)} · #{plan.title}")}</span>
                <button type="button" phx-click="unlink_plan" phx-target={@myself} class="btn btn-ghost btn-xs" title={gettext("Not the record of this plan")}>
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                </button>
              </div>
              <div class="flex flex-wrap items-end gap-3">
                <.input
                  id="crm-duration"
                  type="number"
                  name="interaction[duration_minutes]"
                  value={@c_duration}
                  label={gettext("Duration (minutes)")}
                  min="1"
                  step="1"
                  class="input-sm"
                  wrapper_class="w-40"
                />
                <.checkbox
                  id="crm-billable"
                  name="interaction[billable]"
                  checked={@c_billable}
                  label={gettext("Billable time")}
                  class="checkbox-primary checkbox-sm"
                  wrapper_class="h-8 items-center gap-2! -mb-0.5"
                />
              </div>
              <% attendees = attendees(assigns) %>
              <p :if={is_binary(@editing_uuid) and attendees != []} class="text-xs text-base-content/60">
                {gettext("Minutes per attendee, as logged on the project — change a figure to amend it, 0 removes it; an attendee without one gets an entry on save (blank means the whole duration).")}
              </p>
              <p :if={attendees == []} class="text-xs text-base-content/60">
                {gettext("Add yourself or a staff member under Involved parties to log their time on the project.")}
              </p>
              <p :if={attendees != [] and is_nil(@editing_uuid)} class="text-xs text-base-content/60">
                {gettext("Minutes per attendee — blank means the whole duration.")}
              </p>
              <div :for={a <- attendees} class="flex items-center gap-2">
                <span class="text-sm min-w-32">{a.name}</span>
                <.input
                  id={"crm-attendee-#{a.idx}"}
                  type="number"
                  name={"attendee_minutes[#{a.key}]"}
                  value={Map.get(@attendee_minutes, a.key, logged_value(a))}
                  min="0"
                  step="1"
                  class="input-sm"
                  wrapper_class="w-28"
                  placeholder={@c_duration}
                />
                <span class="text-xs text-base-content/50">
                  {if a[:logged], do: gettext("minutes, logged"), else: gettext("minutes")}
                </span>
              </div>
            </div>
          </.form>

          <%!-- Attachments — real inline drag-drop / click dropzone (uploads
                like core's media picker); staged files attach on save. --%>
          <div :if={@can_attach and is_nil(@editing_uuid)} class="flex flex-col gap-2">
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

            <div :if={@upload_error} class="text-xs text-error" role="alert">{@upload_error}</div>

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

          <div class="flex justify-end gap-2">
            <.button
              :if={@editing_uuid}
              type="button"
              phx-click="cancel_edit"
              phx-target={@myself}
              class="btn-ghost btn-sm"
            >
              {gettext("Cancel")}
            </.button>
            <.button
              type="button"
              phx-click="save_interaction"
              phx-target={@myself}
              class="btn-primary btn-sm"
              phx-disable-with={gettext("Saving…")}
            >
              {if @editing_uuid, do: gettext("Save changes"), else: gettext("Save interaction")}
            </.button>
          </div>
        </div>
      </div>

      <%!-- Scope filter (company mode): the company's own interactions vs the
           member rollup. Segmented buttons, not counted index tabs — the feed
           is one query and this is a view split, not navigation. --%>
      <div :if={@show_feed and @anchor_kind == :company and not @project_mode} class="flex items-center gap-1">
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
        :if={@show_feed and @interactions == []}
        icon="hero-chat-bubble-left-right"
        title={gettext("No interactions logged yet.")}
      />

      <ol :if={@show_feed and @interactions != []} class="flex flex-col gap-3">
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
              <%!-- One menu per row, core's: edit and delete on the rows this
                   page anchors; in project mode also the way to the CRM and
                   a task from this meeting. --%>
              <% owned = @can_write and owns_row?(assigns, i) %>
              <% add_url = @project_mode and @can_write && add_task_url(assigns, i) %>
              <.table_row_menu :if={owned or @project_mode} id={"crm-interaction-menu-#{i.uuid}"}>
                <.table_row_menu_button
                  :if={owned}
                  phx-click="edit_interaction"
                  phx-value-uuid={i.uuid}
                  phx-target={@myself}
                  icon="hero-pencil"
                  label={gettext("Edit")}
                />
                <.table_row_menu_link
                  :if={@project_mode}
                  navigate={crm_path(i)}
                  icon="hero-arrow-top-right-on-square"
                  label={gettext("Open in CRM")}
                />
                <.table_row_menu_link
                  :if={add_url}
                  navigate={add_url}
                  icon="hero-plus"
                  label={gettext("Add task")}
                />
                <.table_row_menu_divider :if={owned} />
                <.table_row_menu_button
                  :if={owned}
                  phx-click="delete_interaction"
                  phx-value-uuid={i.uuid}
                  phx-target={@myself}
                  phx-disable-with={gettext("Deleting…")}
                  data-confirm={gettext("Delete this interaction?")}
                  icon="hero-trash"
                  label={gettext("Delete")}
                  variant="error"
                />
              </.table_row_menu>
            </div>
            <div :if={i.subject} class="font-medium">{i.subject}</div>
            <div :if={i.body} class="text-sm whitespace-pre-wrap">{i.body}</div>
            <div :if={i.parties != []} class="flex flex-wrap gap-1 mt-1">
              <span class="text-xs text-base-content/50">{gettext("Involved:")}</span>
              <.party_badge :for={p <- i.parties} party={p} />
            </div>

            <%!-- Project mode: the meeting's length, what came out of it
                 (the tasks whose description carries this row's # chip),
                 and the way to add one more. --%>
            <div :if={@project_mode} class="flex flex-wrap items-center gap-2 mt-1 text-xs">
              <span :if={i.duration_minutes} class="badge badge-ghost badge-sm gap-1">
                <.icon name="hero-clock" class="w-3 h-3" /> {format_minutes(i.duration_minutes)}
              </span>
              <% planned = planned_label(i, assigns) %>
              <span
                :if={planned}
                class="badge badge-outline badge-sm gap-1"
                title={gettext("The project event this is the record of")}
              >
                <.icon name="hero-calendar" class="w-3 h-3" /> {planned}
              </span>
              <% links = Map.get(@interaction_links, i.uuid, []) %>
              <span :if={links != []} class="text-base-content/50">{gettext("Tasks from this:")}</span>
              <.link
                :for={l <- links}
                navigate={l.url}
                class="badge badge-outline badge-sm link link-hover"
              >
                {l.title}
              </.link>
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
