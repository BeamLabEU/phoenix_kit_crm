defmodule PhoenixKitCRM.ProjectColumns do
  @moduledoc """
  The CRM's column on the projects list: **Client** — the company a
  project's Client extension is linked to, by name, with a link to the
  company's page (the `project_columns:` of the extension declaration in
  `phoenix_kit_project_extensions/0`).

  The projects module is not a dependency: it reaches this one by name
  with a whole page of project uuids and gets plain maps back, so this is
  a fixed number of reads however many projects are listed — the Client rows' own
  `config["company_uuid"]` (the extension's enablement table, read
  schemaless, as it belongs to another module), then the companies. The
  hub drops the values of projects the extension is switched off on.
  """

  use Gettext, backend: PhoenixKitCRM.Gettext

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.Paths
  alias PhoenixKitCRM.Schemas.Company

  @ext_key "crm_client"
  @placeholder "00000000-0000-0000-0000-000000000000"

  @type column :: %{
          key: String.t(),
          label: String.t(),
          values: %{String.t() => %{text: String.t(), url: String.t()}}
        }

  @doc """
  The Client column for `project_uuids`: `values` maps a project to its
  client's `%{text: name, url: company page}`. A project with no client, a
  client that is gone or trashed, simply has no value. With `[]` it is the
  column alone, for the list's picker.
  """
  @spec for_projects([String.t()]) :: [column()]
  def for_projects(project_uuids) when is_list(project_uuids) do
    [%{key: "client", label: gettext("Client"), values: values(project_uuids)}]
  end

  defp values([]), do: %{}

  defp values(project_uuids) do
    company_by_project = linked_companies(project_uuids)
    names = company_names(company_by_project |> Map.values() |> Enum.uniq())

    # One path, built once: `Paths.company/1` resolves the site's URL prefix
    # and locale each time it is called, which is a settings read per row
    # where those are not cached.
    path = Paths.company(@placeholder)

    for {project_uuid, company_uuid} <- company_by_project,
        name = Map.get(names, company_uuid),
        into: %{} do
      {project_uuid, %{text: name, url: String.replace(path, @placeholder, company_uuid)}}
    end
  rescue
    # No projects module on this install (its table is not there), or a
    # read that failed: the list still renders, without clients.
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # `%{project_uuid => company_uuid}` off the Client extension's rows. The
  # stored value is whatever the config form saved, so anything that is not
  # a uuid is dropped here rather than raised on in the next query.
  defp linked_companies(project_uuids) do
    from(m in "phoenix_kit_project_modules",
      where:
        m.project_uuid in type(^project_uuids, {:array, UUIDv7}) and m.ext_key == ^@ext_key and
          m.instance_key == "default",
      select: {type(m.project_uuid, UUIDv7), fragment("?->>'company_uuid'", m.config)}
    )
    |> RepoHelper.repo().all()
    |> Enum.flat_map(fn {project_uuid, company_uuid} ->
      case is_binary(company_uuid) && Ecto.UUID.cast(company_uuid) do
        {:ok, uuid} -> [{project_uuid, uuid}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp company_names([]), do: %{}

  defp company_names(company_uuids) do
    from(c in Company,
      where: c.uuid in ^company_uuids and c.status != "trashed",
      select: {c.uuid, c.name}
    )
    |> RepoHelper.repo().all()
    |> Map.new()
  end
end
