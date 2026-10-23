defmodule PhoenixKitCRM.ProjectColumnsTest do
  @moduledoc """
  The Client column the CRM puts on the projects list: the linked
  company's name and page for a whole page of projects, in a fixed number
  of reads.
  """

  use PhoenixKitCRM.DataCase, async: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.{Companies, Paths, ProjectColumns}

  # The Client extension's rows live in the projects module's table, which
  # this repo's tests do not have: a stand-in with the columns the read
  # uses, rolled back with the test.
  defp modules_table! do
    RepoHelper.repo().query!("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_project_modules (
      uuid uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
      project_uuid uuid NOT NULL,
      ext_key varchar(100) NOT NULL,
      instance_key varchar(100) NOT NULL DEFAULT 'default',
      enabled boolean NOT NULL DEFAULT true,
      config jsonb NOT NULL DEFAULT '{}'
    )
    """)
  end

  defp link!(project_uuid, config, ext_key \\ "crm_client") do
    RepoHelper.repo().query!(
      "INSERT INTO phoenix_kit_project_modules (project_uuid, ext_key, config) VALUES ($1, $2, $3)",
      [Ecto.UUID.dump!(project_uuid), ext_key, config]
    )
  end

  defp count_queries(fun) do
    handler = "crm-columns-#{System.unique_integer([:positive])}"
    parent = self()
    event = RepoHelper.repo().config()[:telemetry_prefix] ++ [:query]

    :telemetry.attach(handler, event, fn _, _, _, _ -> send(parent, handler) end, nil)

    try do
      result = fun.()
      {result, drain(handler, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, n) do
    receive do
      ^handler -> drain(handler, n + 1)
    after
      0 -> n
    end
  end

  test "with no projects it is the column alone" do
    assert [%{key: "client", label: "Client", values: %{}}] = ProjectColumns.for_projects([])
  end

  test "without the projects module's table there are no clients, and nothing raises" do
    assert [%{key: "client", values: %{}}] = ProjectColumns.for_projects([Ecto.UUID.generate()])
  end

  test "a project's client is the linked company, by name, with its page" do
    modules_table!()
    {:ok, acme} = Companies.create_company(%{"name" => "Acme Furniture OÜ"})
    {:ok, gone} = Companies.create_company(%{"name" => "Gone"})
    {:ok, _} = Companies.trash_company(gone)

    with_client = Ecto.UUID.generate()
    same_client = Ecto.UUID.generate()
    trashed_client = Ecto.UUID.generate()
    no_company = Ecto.UUID.generate()
    garbage = Ecto.UUID.generate()
    other_ext = Ecto.UUID.generate()
    not_asked = Ecto.UUID.generate()

    link!(with_client, %{"company_uuid" => acme.uuid})
    link!(same_client, %{"company_uuid" => acme.uuid})
    link!(trashed_client, %{"company_uuid" => gone.uuid})
    link!(no_company, %{})
    link!(garbage, %{"company_uuid" => "not a uuid"})
    link!(other_ext, %{"company_uuid" => acme.uuid}, "something_else")
    link!(not_asked, %{"company_uuid" => acme.uuid})

    asked = [with_client, same_client, trashed_client, no_company, garbage, other_ext]
    assert [%{key: "client", values: values}] = ProjectColumns.for_projects(asked)

    client = %{text: "Acme Furniture OÜ", url: Paths.company(acme.uuid)}
    assert values == %{with_client => client, same_client => client}
  end

  test "the reads do not grow with the number of projects" do
    modules_table!()
    {:ok, company} = Companies.create_company(%{"name" => "Acme"})

    projects =
      for _ <- 1..8 do
        uuid = Ecto.UUID.generate()
        link!(uuid, %{"company_uuid" => company.uuid})
        uuid
      end

    {_, one} = count_queries(fn -> ProjectColumns.for_projects(Enum.take(projects, 1)) end)
    {[%{values: values}], many} = count_queries(fn -> ProjectColumns.for_projects(projects) end)

    assert map_size(values) == 8
    # the rows, the companies, and one path's worth of settings — never per project
    assert one == many
  end

  test "the Client extension declares the column" do
    [ext] = PhoenixKitCRM.phoenix_kit_project_extensions()
    assert ext.project_columns == {PhoenixKitCRM.ProjectColumns, :for_projects}
  end
end
