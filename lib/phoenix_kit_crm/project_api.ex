defmodule PhoenixKitCRM.ProjectApi do
  # `apply/3` on purpose for the one call into the projects hub (not a
  # dependency of this module), the `StaffLink` / `ProjectsLink` pattern.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  A project's interactions on the projects JSON API — the
  `PhoenixKitProjects.Extensions.ApiProvider` the Client extension declares
  (`api:` in `phoenix_kit_project_extensions/0`). The projects module
  serves

      GET/POST  /api/projects/v1/ext/interactions
      GET/PATCH /api/projects/v1/ext/interactions/:id

  with its usual checks (scopes `interactions:read` / `interactions:write`,
  the Client extension on, the key's role at `log_interaction`) and hands
  the work here with a `ctx` (`project`, `key`, `user_uuid` = the person
  the key acts for, else the one who minted it, `actor`). What an agent may write: `status`
  (`planned` | `happened` | `cancelled` — V9; a plan is the same row the
  record will be, logged by PATCHing its status), `type`, `subject`,
  `body`, `location`, `occurred_at` (ISO 8601, any offset; in the future only
  for a plan or a cancellation), `time_zone`,
  `duration_minutes` (or `ended_at`, the same said as a moment), `parties` (`{name, contact_uuid?, staff_person_uuid?}`
  — a replace, never a merge), and `event_uuid` (the project event this
  interaction is the record of — the plan → record link). The anchor is the
  project's client company and never changes; time entries are the ledger's
  business (the projects API's own `/time` calls).

  This module adopts the behaviour by name only: `phoenix_kit_projects` is
  not a dependency of the CRM, so the behaviour module may be absent at
  compile time — the callbacks are plain public functions the projects
  side reaches through `apply/3`.
  """

  alias PhoenixKitCRM.{Companies, Contacts, Interactions, ProjectsLink, StaffLink}
  alias PhoenixKitCRM.Schemas.{Company, Interaction}

  @resource "interactions"
  @read "interactions:read"
  @write "interactions:write"
  @future_tolerance_seconds 300

  @doc false
  def resource, do: @resource

  @doc false
  def scopes, do: %{read: @read, write: @write}

  @doc false
  def action, do: :log_interaction

  # ── Reads ───────────────────────────────────────────────────────────

  @doc false
  def list(%{project: project}, params) do
    limit = list_limit(params["limit"])
    since = parse_since(params["since"])

    with {:ok, statuses} <- status_filter(params["status"]),
         {:ok, updated_since} <- updated_since(params["updated_since"]) do
      rows =
        project.uuid
        |> Interactions.list_for_project(limit: 200)
        |> Enum.filter(&listed?(&1, statuses, since, updated_since))
        |> order_for(statuses)
        |> Enum.take(limit)

      {:ok,
       %{
         interactions: Enum.map(rows, &to_json/1),
         count: length(rows),
         now: DateTime.utc_now() |> DateTime.truncate(:second)
       }}
    end
  end

  defp listed?(i, statuses, since, updated_since) do
    i.status in statuses and
      (is_nil(since) or DateTime.compare(i.occurred_at, since) == :gt) and
      (is_nil(updated_since) or DateTime.compare(i.updated_at, updated_since) != :lt)
  end

  # Which statuses a list answers. Unsaid, it is the record — what happened
  # and what was cancelled — as it was before plans existed; `planned` is
  # the plan (soonest first), `all` is everything.
  defp status_filter(nil), do: {:ok, ["happened", "cancelled"]}
  defp status_filter("all"), do: {:ok, Interaction.statuses()}

  defp status_filter(v) when is_binary(v) do
    wanted = v |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if wanted != [] and Enum.all?(wanted, &(&1 in Interaction.statuses())),
      do: {:ok, wanted},
      else: invalid("status", "must be all, or any of #{Enum.join(Interaction.statuses(), ", ")}")
  end

  defp status_filter(_), do: invalid("status", "must be a string")

  defp updated_since(nil), do: {:ok, nil}

  defp updated_since(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> invalid("updated_since", "must be an ISO 8601 datetime")
    end
  end

  defp updated_since(_), do: invalid("updated_since", "must be an ISO 8601 datetime")

  # Plans alone read soonest first; anything else newest first, as loaded.
  defp order_for(rows, ["planned"]), do: Enum.sort_by(rows, & &1.occurred_at, {:asc, DateTime})
  defp order_for(rows, _statuses), do: rows

  defp list_limit(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> min(n, 200)
      _ -> 200
    end
  end

  defp list_limit(n) when is_integer(n) and n > 0, do: min(n, 200)
  defp list_limit(_), do: 200

  defp parse_since(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_since(_), do: nil

  @doc false
  def get(%{project: project}, id) do
    case fetch(project, id) do
      {:ok, i} -> {:ok, %{interaction: to_json(i)}}
      error -> error
    end
  end

  # ── Writes ──────────────────────────────────────────────────────────

  @doc false
  def create(%{project: project, user_uuid: user_uuid} = ctx, attrs) do
    with {:ok, company_uuid} <- client_company(project),
         {:ok, fields} <- validate(attrs, :create, nil),
         :ok <- check_time(fields, nil),
         {:ok, parties} <- parties(attrs["parties"], required: false),
         :ok <- check_tasks(project, attrs["tasks"]) do
      row_attrs =
        fields
        |> Map.merge(%{
          "company_uuid" => company_uuid,
          "project_uuid" => project.uuid,
          "owner_user_uuid" => user_uuid
        })
        |> put_metadata(%{}, attrs, ctx)

      row_attrs
      |> Interactions.create_interaction(parties || [])
      |> answer(attrs, ctx, 201)
    end
  end

  @doc false
  def update(%{project: project} = ctx, id, attrs) do
    with {:ok, i} <- fetch(project, id),
         {:ok, fields} <- validate(attrs, :update, i.occurred_at),
         :ok <- check_time(fields, i),
         {:ok, parties} <- parties(attrs["parties"], required: false),
         :ok <- check_tasks(project, attrs["tasks"]) do
      row_attrs = put_metadata(fields, i.metadata, attrs, ctx)

      i
      |> Interactions.update_interaction(row_attrs, parties, actor_uuid: ctx[:user_uuid])
      |> answer(attrs, ctx, nil)
    end
  end

  # A write's answer: the tasks linked, then the row re-read so its
  # `tasks` are in the shape.
  defp answer({:ok, i}, attrs, ctx, status) do
    with :ok <- link_tasks(i, attrs["tasks"], ctx) do
      json = %{interaction: to_json(Interactions.get_interaction(i.uuid) || i)}
      if status, do: {:ok, json, status}, else: {:ok, json}
    end
  end

  defp answer({:error, %Ecto.Changeset{} = cs}, _attrs, _ctx, _status), do: changeset_error(cs)

  # `tasks: [uuid]` is checked BEFORE the interaction is written: a list of
  # uuids, each a task of this project or a sub-project under it — a task
  # elsewhere on the site is not this interaction's to touch (404), a
  # malformed list a 422. Then each gains the link (`ProjectsLink.link_task/3`:
  # the projects module's own table, plus the mention token). Not a
  # replace: a task once linked stays linked.
  defp check_tasks(_project, nil), do: :ok

  defp check_tasks(project, uuids) when is_list(uuids) do
    if Enum.all?(uuids, &(is_binary(&1) and match?({:ok, _}, Ecto.UUID.cast(&1)))) do
      reach = ProjectsLink.subtree_uuids(project.uuid)

      case Enum.find(uuids, &(ProjectsLink.task_project(&1) not in reach)) do
        nil ->
          :ok

        uuid ->
          {:error, {404, "not_found", "No such task on this project: #{uuid}.", %{task: uuid}}}
      end
    else
      {:error,
       {422, "validation_failed", "tasks must be a list of task uuids.",
        %{tasks: ["must be uuids"]}}}
    end
  end

  defp check_tasks(_project, _),
    do: {:error, {422, "validation_failed", "tasks must be a list of task uuids.", nil}}

  defp link_tasks(_i, nil, _ctx), do: :ok

  defp link_tasks(i, uuids, ctx) when is_list(uuids) do
    Enum.reduce_while(uuids, :ok, fn uuid, :ok ->
      case ProjectsLink.link_task(uuid, i, actor_uuid: ctx[:user_uuid]) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, :not_found} ->
          {:halt, {:error, {404, "not_found", "No such task: #{uuid}.", %{task: uuid}}}}

        {:error, _} ->
          {:halt, {:error, {422, "validation_failed", "The task could not be linked.", nil}}}
      end
    end)
  end

  defp link_tasks(_i, _, _ctx), do: :ok

  # ── Shapes ──────────────────────────────────────────────────────────

  @doc "The JSON shape of an interaction on the API."
  @spec to_json(Interaction.t()) :: map()
  def to_json(%Interaction{} = i) do
    parties = if Ecto.assoc_loaded?(i.parties), do: i.parties, else: []

    %{
      uuid: i.uuid,
      # planned | happened | cancelled; a plan past its time with nothing
      # said about it is `overdue` (never flipped by the clock)
      status: i.status,
      overdue: Interaction.overdue?(i),
      type: i.interaction_type,
      subject: i.subject,
      body: i.body,
      location: i.location,
      # while planned: when it is meant to start; afterwards: when it did
      occurred_at: i.occurred_at,
      # the start that was agreed, kept once the real one is known; null on
      # a row that was never a plan
      planned_at: i.planned_at,
      time_zone: i.time_zone,
      duration_minutes: i.duration_minutes,
      # the start plus the length; null when no length was given
      ended_at: Interaction.ended_at(i),
      company_uuid: i.company_uuid,
      contact_uuid: i.contact_uuid,
      event_uuid: (i.metadata || %{})["event_uuid"],
      tasks: linked_tasks(i),
      parties:
        Enum.map(parties, fn p ->
          %{
            name: p.raw_name,
            contact_uuid: p.contact_uuid,
            staff_person_uuid: p.staff_person_uuid
          }
        end),
      inserted_at: i.inserted_at,
      updated_at: i.updated_at
    }
  end

  # The tasks that came out of this interaction (the projects module's
  # link table, else the mention backlinks).
  defp linked_tasks(%Interaction{uuid: uuid}), do: ProjectsLink.tasks_for_interaction(uuid)

  @doc "Endpoint rows for the projects API docs."
  @spec docs() :: [map()]
  def docs do
    body = [
      %{
        name: "status",
        in: :body,
        type: "string",
        required: false,
        doc:
          "planned | happened | cancelled (default happened). A plan is the same row the record will be: PATCH its status to happened (with what was discussed, the real start and length) or to cancelled (say why in body; time it still cost can be given as a length)."
      },
      %{
        name: "location",
        in: :body,
        type: "string",
        required: false,
        doc: "where, ≤ 200"
      },
      %{
        name: "type",
        in: :body,
        type: "string",
        required: false,
        doc: "call | email | meeting | message | note | other (default meeting)"
      },
      %{name: "subject", in: :body, type: "string", required: false, doc: "one line, ≤ 255"},
      %{name: "body", in: :body, type: "string", required: false, doc: "what was discussed"},
      %{
        name: "occurred_at",
        in: :body,
        type: "string",
        required: false,
        doc:
          "ISO 8601 datetime with offset: when it happened (default now), or for a plan when it is meant to start. In the future only with status planned or cancelled."
      },
      %{
        name: "time_zone",
        in: :body,
        type: "string",
        required: false,
        doc: "IANA zone the time was given in, e.g. Europe/Tallinn"
      },
      %{
        name: "duration_minutes",
        in: :body,
        type: "integer",
        required: false,
        doc: "how long it took, whole minutes (1–1440)"
      },
      %{
        name: "ended_at",
        in: :body,
        type: "string",
        required: false,
        doc:
          "ISO 8601 datetime with offset, when it ended - the length said another way (stored as `duration_minutes` from the start); send this or `duration_minutes`, and if both they must agree"
      },
      %{
        name: "parties",
        in: :body,
        type: "array",
        required: false,
        doc:
          "who was involved: objects {name, contact_uuid?, staff_person_uuid?} — at most one of the two uuids; REPLACES the list when sent"
      },
      %{
        name: "event_uuid",
        in: :body,
        type: "string",
        required: false,
        doc: "the project event (the plan) this is the record of; null to unlink"
      },
      %{
        name: "tasks",
        in: :body,
        type: "array",
        required: false,
        doc:
          "task uuids that came out of this interaction; each gains its link (never unlinked here)"
      }
    ]

    [
      %{
        id: "listInteractions",
        method: "GET",
        path: "/ext/interactions",
        summary:
          "The project's interactions with its client — meetings, calls, messages — newest first, with who was involved and how long. Without `status` this is the record (happened and cancelled); `status=planned` is what is planned, soonest first, each with `overdue` when its time has passed and nobody has said what happened. Needs the Client extension on the project.",
        auth: true,
        scope: @read,
        action: "view",
        feature: "crm_client",
        idempotency: nil,
        params: [
          %{
            name: "status",
            in: :query,
            type: "string",
            required: false,
            doc:
              "planned | happened | cancelled, several with commas, or all (default: happened,cancelled)"
          },
          %{
            name: "since",
            in: :query,
            type: "string",
            required: false,
            doc: "ISO 8601; only interactions whose occurred_at is after that moment"
          },
          %{
            name: "updated_since",
            in: :query,
            type: "string",
            required: false,
            doc:
              "ISO 8601; only rows changed at or after that moment — the one to poll with (pass the last answer's `now`), since a plan changes after it is first seen: it moves, is logged, is cancelled"
          },
          %{
            name: "limit",
            in: :query,
            type: "integer",
            required: false,
            doc: "at most this many, newest first (200 at most)"
          }
        ],
        example: nil
      },
      %{
        id: "createInteraction",
        method: "POST",
        path: "/ext/interactions",
        summary:
          "Log an interaction with the client on this project (a meeting by default), or plan one with `status: \"planned\"` and a future `occurred_at`. The client company is the project's; you cannot pick another. Time spent is NOT logged here — use POST /time with occurred_at for each attendee, once it has happened. The people a plan names are notified. Idempotency-Key honoured.",
        auth: true,
        scope: @write,
        action: "log_interaction",
        feature: "crm_client",
        idempotency: :optional,
        params: body,
        example:
          ~s({"type": "meeting", "subject": "Kickoff at the client's office", "occurred_at": "2026-10-04T14:03:00+03:00", "time_zone": "Europe/Tallinn", "duration_minutes": 180, "body": "Agreed the scope.", "parties": [{"name": "Max Don"}, {"name": "Maria", "contact_uuid": "…"}]})
      },
      %{
        id: "getInteraction",
        method: "GET",
        path: "/ext/interactions/{id}",
        summary: "One interaction of this project.",
        auth: true,
        scope: @read,
        action: "view",
        feature: "crm_client",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      },
      %{
        id: "updateInteraction",
        method: "PATCH",
        path: "/ext/interactions/{id}",
        summary:
          "Edit an interaction: any of the fields of POST; `parties` replaces the whole list when sent. This is also how a plan is moved (a new `occurred_at`), logged (`status: \"happened\"`) or cancelled (`status: \"cancelled\"`). The anchor company never changes.",
        auth: true,
        scope: @write,
        action: "log_interaction",
        feature: "crm_client",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""} | body],
        example: ~s({"duration_minutes": 180, "body": "Three hours; see the notes."})
      }
    ]
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp fetch(project, id) do
    case Interactions.get_for_project(project.uuid, id) do
      %Interaction{} = i -> {:ok, i}
      _ -> {:error, {404, "not_found", "No such interaction on this project.", nil}}
    end
  end

  # The project's client company, from the Client extension's config —
  # the only anchor an API-logged interaction can have.
  defp client_company(project) do
    with uuid when is_binary(uuid) and uuid != "" <- client_company_uuid(project),
         %Company{} <- Companies.get_company(uuid) do
      {:ok, uuid}
    else
      _ ->
        {:error,
         {409, "no_client",
          "The project has no client company set; pick one in Modules & features first.", nil}}
    end
  end

  # `PhoenixKitProjects.Extensions.config/2` is the hub's; reached by name,
  # the CRM does not depend on the projects package.
  @doc false
  def client_company_uuid(project) do
    mod = PhoenixKitProjects.Extensions

    if Code.ensure_loaded?(mod) and function_exported?(mod, :config, 2) do
      project |> then(&apply(mod, :config, [&1, "crm_client"])) |> Map.get("company_uuid")
    end
  rescue
    _ -> nil
  end

  defp validate(attrs, mode, started) do
    with {:ok, type} <- type(attrs["type"], mode),
         {:ok, status} <- status(attrs["status"]),
         {:ok, location} <- string(attrs["location"], "location", 200),
         {:ok, subject} <- string(attrs["subject"], "subject", 255),
         {:ok, body} <- string(attrs["body"], "body", 20_000),
         {:ok, occurred_at} <- occurred_at(attrs["occurred_at"]),
         {:ok, tz} <- string(attrs["time_zone"], "time_zone", 64),
         {:ok, minutes} <- duration(attrs["duration_minutes"]),
         {:ok, minutes} <- ended_at(attrs["ended_at"], occurred_at || started, minutes),
         :ok <- event_uuid(attrs["event_uuid"]) do
      fields =
        %{}
        |> put_if("interaction_type", type)
        |> put_if("status", status)
        |> put_if("location", location)
        |> put_if("subject", subject)
        |> put_if("body", body)
        |> put_if("occurred_at", occurred_at)
        |> put_if("time_zone", tz)
        |> put_if("duration_minutes", minutes)

      {:ok, fields}
    end
  end

  defp type(nil, :create), do: {:ok, "meeting"}
  defp type(nil, :update), do: {:ok, nil}

  defp type(t, _mode) do
    if t in Interaction.types(),
      do: {:ok, t},
      else: invalid("type", "must be one of #{Enum.join(Interaction.types(), ", ")}")
  end

  defp status(nil), do: {:ok, nil}

  defp status(s) do
    if s in Interaction.statuses(),
      do: {:ok, s},
      else: invalid("status", "must be one of #{Enum.join(Interaction.statuses(), ", ")}")
  end

  # A record cannot be of something still to come: the start may be in the
  # future only for a plan, or for one cancelled ahead of its time. Read
  # against what the row WILL be — the fields sent over the row's own.
  defp check_time(fields, existing) do
    status = fields["status"] || (existing && existing.status) || "happened"
    at = fields["occurred_at"] || (existing && existing.occurred_at)

    if status == "happened" and match?(%DateTime{}, at) and
         DateTime.diff(at, DateTime.utc_now(), :second) > @future_tolerance_seconds do
      invalid(
        "occurred_at",
        "is in the future: send status planned to plan it, or when it really happened"
      )
    else
      :ok
    end
  end

  defp string(nil, _field, _max), do: {:ok, nil}

  defp string(v, field, max) when is_binary(v) do
    cond do
      String.contains?(v, <<0>>) -> invalid(field, "must not contain null bytes")
      String.length(v) > max -> invalid(field, "at most #{max} characters")
      true -> {:ok, v}
    end
  end

  defp string(_, field, _max), do: invalid(field, "must be a string")

  # The plan → record link is a uuid or null; anything else was either
  # silently dropped (a number) or stored as free text on the row (a string).
  defp event_uuid(nil), do: :ok

  defp event_uuid(v) when is_binary(v) do
    if match?({:ok, _}, Ecto.UUID.cast(v)), do: :ok, else: invalid("event_uuid", "must be a uuid")
  end

  defp event_uuid(_), do: invalid("event_uuid", "must be a uuid or null")

  defp duration(nil), do: {:ok, nil}
  defp duration(n) when is_integer(n) and n > 0 and n <= 1440, do: {:ok, n}
  defp duration(_), do: invalid("duration_minutes", "must be whole minutes, 1–1440")

  # `ended_at` is the length said another way: the row stores a start and
  # whole minutes, so an end is turned into minutes from the start (the one
  # sent, or the row's own on an update). Sent with `duration_minutes`, the
  # two must agree.
  defp ended_at(nil, _start, minutes), do: {:ok, minutes}

  defp ended_at(value, %DateTime{} = start, minutes) when is_binary(value) do
    with {:ok, dt, _} <- DateTime.from_iso8601(value),
         span = DateTime.diff(DateTime.truncate(dt, :second), start, :minute),
         {:ok, span} <- duration(span) do
      if is_nil(minutes) or minutes == span,
        do: {:ok, span},
        else: invalid("ended_at", "does not agree with duration_minutes; send one of the two")
    else
      {:error, {422, _, _, %{"duration_minutes" => _}}} ->
        invalid("ended_at", "must be after the start, by at most 1440 minutes")

      _ ->
        invalid("ended_at", "must be an ISO 8601 datetime")
    end
  end

  defp ended_at(value, nil, _minutes) when is_binary(value),
    do: invalid("ended_at", "needs occurred_at: an end is measured from the start")

  defp ended_at(_, _start, _minutes), do: invalid("ended_at", "must be an ISO 8601 datetime")

  defp occurred_at(nil), do: {:ok, nil}

  defp occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> invalid("occurred_at", "must be an ISO 8601 datetime")
    end
  end

  defp occurred_at(_), do: invalid("occurred_at", "must be an ISO 8601 datetime")

  # Parties: a replace list — each a name, and at most one resolved
  # reference that must exist. `nil` means "leave as they are".
  defp parties(nil, _opts), do: {:ok, nil}

  defp parties(list, _opts) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {p, idx}, {:ok, acc} ->
      case party(p, idx) do
        {:ok, party} -> {:cont, {:ok, acc ++ [party]}}
        error -> {:halt, error}
      end
    end)
  end

  defp parties(_, _opts),
    do: invalid("parties", "must be a list of {name, contact_uuid?, staff_person_uuid?}")

  defp party(%{} = p, idx) do
    name = p["name"] || ""
    contact = p["contact_uuid"]
    staff = p["staff_person_uuid"]

    # Types first: `to_string/1` on a map raises, and a number in a uuid
    # slot would reach the party's changeset as a non-uuid.
    cond do
      not is_binary(name) -> invalid("parties[#{idx}].name", "must be a string")
      not uuid_or_nil?(contact) -> invalid("parties[#{idx}].contact_uuid", "must be a uuid")
      not uuid_or_nil?(staff) -> invalid("parties[#{idx}].staff_person_uuid", "must be a uuid")
      true -> resolved_party(name, contact, staff, idx)
    end
  end

  defp party(_, idx), do: invalid("parties[#{idx}]", "must be an object")

  defp resolved_party(name, contact, staff, idx) do
    name = String.trim(name)

    case party_error(name, contact, staff, idx) do
      nil -> {:ok, %{raw_name: name, contact_uuid: contact, staff_person_uuid: staff}}
      error -> error
    end
  end

  defp uuid_or_nil?(nil), do: true
  defp uuid_or_nil?(v) when is_binary(v), do: match?({:ok, _}, Ecto.UUID.cast(v))
  defp uuid_or_nil?(_), do: false

  defp party_error(name, _contact, _staff, idx) when name == "" or byte_size(name) > 1020,
    do: invalid("parties[#{idx}].name", "is required, at most 255 characters")

  defp party_error(name, contact, staff, idx) do
    cond do
      String.contains?(name, <<0>>) ->
        invalid("parties[#{idx}].name", "must not contain null bytes")

      String.length(name) > 255 ->
        invalid("parties[#{idx}].name", "is required, at most 255 characters")

      is_binary(contact) and is_binary(staff) ->
        invalid("parties[#{idx}]", "at most one of contact_uuid and staff_person_uuid")

      true ->
        reference_error(contact, staff, idx)
    end
  end

  defp reference_error(contact, _staff, idx) when is_binary(contact) do
    if is_nil(Contacts.get_contact(contact)),
      do: invalid("parties[#{idx}].contact_uuid", "no such contact")
  end

  defp reference_error(_contact, staff, idx) when is_binary(staff) do
    if StaffLink.snapshot(staff) == %{},
      do: invalid("parties[#{idx}].staff_person_uuid", "no such staff person")
  end

  defp reference_error(_, _, _), do: nil

  # The plan → record link and the trail of who wrote through which key,
  # on the row's metadata; an explicit null `event_uuid` unlinks.
  defp put_metadata(fields, existing, attrs, ctx) do
    metadata =
      case Map.fetch(attrs, "event_uuid") do
        {:ok, nil} -> Map.delete(existing, "event_uuid")
        {:ok, uuid} when is_binary(uuid) -> Map.put(existing, "event_uuid", uuid)
        _ -> existing
      end
      |> Map.put("via", "api")
      |> Map.put("api_key", ctx[:key] && ctx.key.uuid)

    Map.put(fields, "metadata", metadata)
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  defp invalid(field, why) do
    {:error, {422, "validation_failed", "#{field} #{why}.", %{field => [why]}}}
  end

  defp changeset_error(cs) do
    details =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    {:error, {422, "validation_failed", "Some fields are invalid.", details}}
  end
end
