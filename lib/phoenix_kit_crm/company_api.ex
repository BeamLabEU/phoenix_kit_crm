defmodule PhoenixKitCRM.CompanyApi do
  @moduledoc """
  The project's client on the projects API — `/ext/companies`: the company
  the project is linked to and the people at it, so an agent reading an
  interaction can answer "who is Maria". Read-only; the same scope as the
  interactions (`interactions:read`), since the client is their context.

      GET /api/projects/v1/ext/companies        — the project's client (one)
      GET /api/projects/v1/ext/companies/:id    — that company, by uuid

  Adopts `PhoenixKitProjects.Extensions.ApiProvider` by name only, like
  `ProjectApi`.
  """

  alias PhoenixKitCRM.{Companies, ProjectApi}
  alias PhoenixKitCRM.Schemas.{Company, Contact}

  @resource "companies"
  @read "interactions:read"
  @write "interactions:write"

  @doc false
  def resource, do: @resource

  @doc false
  def scopes, do: %{read: @read, write: @write}

  @doc false
  def action, do: :log_interaction

  @doc false
  def list(%{project: project}, _params) do
    case client(project) do
      nil -> {:ok, %{companies: [], count: 0}}
      company -> {:ok, %{companies: [to_json(company)], count: 1}}
    end
  end

  @doc false
  def get(%{project: project}, id) do
    case client(project) do
      %Company{uuid: ^id} = company -> {:ok, %{company: to_json(company)}}
      _ -> {:error, {404, "not_found", "No such company on this project.", nil}}
    end
  end

  defp client(project) do
    case ProjectApi.client_company_uuid(project) do
      uuid when is_binary(uuid) and uuid != "" -> Companies.get_company(uuid)
      _ -> nil
    end
  end

  @doc "The JSON shape of the client company, its people included."
  @spec to_json(Company.t()) :: map()
  def to_json(%Company{} = c) do
    people =
      c.uuid
      |> Companies.list_memberships()
      |> Enum.map(fn m ->
        contact = m.contact || %Contact{}

        %{
          uuid: contact.uuid,
          name: contact.name,
          email: contact.email,
          phone: contact.phone,
          role: m.role_in_company,
          department: m.department,
          primary: m.is_primary
        }
      end)

    %{
      uuid: c.uuid,
      name: c.name,
      status: c.status,
      description: c.description,
      website: c.website,
      email: c.email,
      phone: c.phone,
      address: c.address,
      industry: c.industry,
      contacts: people
    }
  end

  @doc "Endpoint rows for the projects API docs."
  @spec docs() :: [map()]
  def docs do
    [
      %{
        id: "listCompanies",
        method: "GET",
        path: "/ext/companies",
        summary:
          "The project's client: the company it is linked to, with the people at it (name, email, phone, role) — so a party's contact_uuid on an interaction has a name. One company per project. Needs the Client extension on the project.",
        auth: true,
        scope: @read,
        action: "view",
        feature: "crm_client",
        idempotency: nil,
        params: [],
        example: nil
      },
      %{
        id: "getCompany",
        method: "GET",
        path: "/ext/companies/{id}",
        summary: "The client company by uuid (only the project's own answers).",
        auth: true,
        scope: @read,
        action: "view",
        feature: "crm_client",
        idempotency: nil,
        params: [%{name: "id", in: :path, type: "uuid", required: true, doc: ""}],
        example: nil
      }
    ]
  end
end
