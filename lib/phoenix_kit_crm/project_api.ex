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
  the key acts for, else the one who minted it, `actor`). What an agent may write: `type`, `subject`,
  `body`, `occurred_at` (ISO 8601, any offset), `time_zone`,
  `duration_minutes`, `parties` (`{name, contact_uuid?, staff_person_uuid?}`
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

    rows =
      project.uuid
      |> Interactions.list_for_project(limit: 200)
      |> Enum.filter(fn i -> is_nil(since) or DateTime.compare(i.occurred_at, since) == :gt end)
      |> Enum.take(limit)

    {:ok,
     %{interactions: Enum.map(rows, &to_json/1), count: length(rows), now: DateTime.utc_now()}}
  end

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
         {:ok, fields} <- validate(attrs, :create),
         {:ok, parties} <- parties(attrs["parties"], required: false) do
      row_attrs =
        fields
        |> Map.merge(%{
          "company_uuid" => company_uuid,
          "project_uuid" => project.uuid,
          "owner_user_uuid" => user_uuid
        })
        |> put_metadata(%{}, attrs, ctx)

      case Interactions.create_interaction(row_attrs, parties || []) do
        {:ok, i} ->
          with :ok <- link_tasks(i, attrs["tasks"], ctx) do
            {:ok, %{interaction: to_json(Interactions.get_interaction(i.uuid) || i)}, 201}
          end

        {:error, %Ecto.Changeset{} = cs} ->
          changeset_error(cs)
      end
    end
  end

  @doc false
  def update(%{project: project} = ctx, id, attrs) do
    with {:ok, i} <- fetch(project, id),
         {:ok, fields} <- validate(attrs, :update),
         {:ok, parties} <- parties(attrs["parties"], required: false) do
      row_attrs = put_metadata(fields, i.metadata, attrs, ctx)

      case Interactions.update_interaction(i, row_attrs, parties, actor_uuid: ctx[:user_uuid]) do
        {:ok, updated} ->
          with :ok <- link_tasks(updated, attrs["tasks"], ctx) do
            {:ok, %{interaction: to_json(updated)}}
          end

        {:error, %Ecto.Changeset{} = cs} ->
          changeset_error(cs)
      end
    end
  end

  # `tasks: [uuid]` — each task gains this interaction's mention token (the
  # same link the meeting's "Add task" button makes); an unknown task is a
  # 404 naming it. Not a replace: a task once linked stays linked.
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

  defp link_tasks(_i, _, _ctx),
    do: {:error, {422, "validation_failed", "tasks must be a list of task uuids.", nil}}

  # ── Shapes ──────────────────────────────────────────────────────────

  @doc "The JSON shape of an interaction on the API."
  @spec to_json(Interaction.t()) :: map()
  def to_json(%Interaction{} = i) do
    parties = if Ecto.assoc_loaded?(i.parties), do: i.parties, else: []

    %{
      uuid: i.uuid,
      type: i.interaction_type,
      subject: i.subject,
      body: i.body,
      occurred_at: i.occurred_at,
      time_zone: i.time_zone,
      duration_minutes: i.duration_minutes,
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

  # The tasks whose description carries this interaction's token — what
  # came out of it — through core's mention index.
  defp linked_tasks(%Interaction{uuid: uuid}) do
    "crm_interaction"
    |> PhoenixKit.Mentions.list_backlinks(uuid, limit: 100)
    |> Enum.filter(&(&1.source_type == "project_task"))
    |> Enum.map(&%{uuid: &1.source_uuid, title: ProjectsLink.task_label(&1.source_uuid)})
    |> Enum.reject(&is_nil(&1.title))
  rescue
    _ -> []
  end

  @doc "Endpoint rows for the projects API docs."
  @spec docs() :: [map()]
  def docs do
    body = [
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
        doc: "ISO 8601 datetime with offset, when it happened (default now); not in the future"
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
          "The project's interactions with its client — meetings, calls, messages — newest first, with who was involved, how long, and the planned event each is the record of. Needs the Client extension on the project.",
        auth: true,
        scope: @read,
        action: "view",
        feature: "crm_client",
        idempotency: nil,
        params: [
          %{
            name: "since",
            in: :query,
            type: "string",
            required: false,
            doc: "ISO 8601; only interactions after that moment"
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
          "Log an interaction with the client on this project (a meeting by default). The client company is the project's; you cannot pick another. Time spent is NOT logged here — use POST /time with occurred_at for each attendee. Idempotency-Key honoured.",
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
          "Edit an interaction: any of the fields of POST; `parties` replaces the whole list when sent; `event_uuid` links it to the planned event (null unlinks). The anchor company never changes.",
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
    case Interactions.get_interaction(id) do
      %Interaction{project_uuid: pu} = i when pu == project.uuid -> {:ok, i}
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

  defp validate(attrs, mode) do
    with {:ok, type} <- type(attrs["type"], mode),
         {:ok, subject} <- string(attrs["subject"], "subject", 255),
         {:ok, body} <- string(attrs["body"], "body", 20_000),
         {:ok, occurred_at} <- occurred_at(attrs["occurred_at"]),
         {:ok, tz} <- string(attrs["time_zone"], "time_zone", 64),
         {:ok, minutes} <- duration(attrs["duration_minutes"]) do
      fields =
        %{}
        |> put_if("interaction_type", type)
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

  defp string(nil, _field, _max), do: {:ok, nil}

  defp string(v, field, max) when is_binary(v) do
    if String.length(v) <= max, do: {:ok, v}, else: invalid(field, "at most #{max} characters")
  end

  defp string(_, field, _max), do: invalid(field, "must be a string")

  defp duration(nil), do: {:ok, nil}
  defp duration(n) when is_integer(n) and n > 0 and n <= 1440, do: {:ok, n}
  defp duration(_), do: invalid("duration_minutes", "must be whole minutes, 1–1440")

  defp occurred_at(nil), do: {:ok, nil}

  defp occurred_at(value) when is_binary(value) do
    with {:ok, dt, _} <- DateTime.from_iso8601(value),
         dt = DateTime.truncate(dt, :second),
         true <- DateTime.diff(dt, DateTime.utc_now(), :second) <= @future_tolerance_seconds do
      {:ok, dt}
    else
      false -> invalid("occurred_at", "must not be in the future")
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
    name = to_string(p["name"] || "")
    contact = p["contact_uuid"]
    staff = p["staff_person_uuid"]

    case party_error(name, contact, staff, idx) do
      nil -> {:ok, %{raw_name: name, contact_uuid: contact, staff_person_uuid: staff}}
      error -> error
    end
  end

  defp party(_, idx), do: invalid("parties[#{idx}]", "must be an object")

  defp party_error(name, _contact, _staff, idx) when name == "" or byte_size(name) > 1020,
    do: invalid("parties[#{idx}].name", "is required, at most 255 characters")

  defp party_error(name, contact, staff, idx) do
    cond do
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
