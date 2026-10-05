defmodule PhoenixKitCRM.CompanyApiTest do
  @moduledoc "The client company on the projects API, and the interactions list's since/limit."

  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.{Companies, CompanyApi, Contacts, Interactions, ProjectApi}
  alias PhoenixKitCRM.Schemas.CompanyMembership

  test "the company resource answers with the client's people; nothing without a client" do
    {:ok, company} = Companies.create_company(%{"name" => "ANDI"})
    {:ok, contact} = Contacts.create_contact(%{"name" => "Maria Kottel", "email" => "m@andi.ee"})

    {:ok, _} =
      %CompanyMembership{}
      |> CompanyMembership.changeset(%{
        "company_uuid" => company.uuid,
        "contact_uuid" => contact.uuid,
        "role_in_company" => "owner"
      })
      |> RepoHelper.repo().insert()

    json = CompanyApi.to_json(Companies.get_company(company.uuid))
    assert json.name == "ANDI"
    assert [%{name: "Maria Kottel", email: "m@andi.ee", role: "owner"}] = json.contacts

    # without the projects module there is no client link to read
    assert {:ok, %{companies: [], count: 0}} =
             CompanyApi.list(%{project: %{uuid: Ecto.UUID.generate()}}, %{})

    assert {:error, {404, "not_found", _, _}} =
             CompanyApi.get(%{project: %{uuid: Ecto.UUID.generate()}}, company.uuid)

    assert CompanyApi.resource() == "companies"
    assert CompanyApi.scopes().read == ProjectApi.scopes().read
    assert [%{id: "listCompanies"}, %{id: "getCompany"}] = CompanyApi.docs()
  end

  test "tasks on an interaction are checked before anything is written" do
    {:ok, company} = Companies.create_company(%{"name" => "ANDI"})
    project_uuid = Ecto.UUID.generate()

    {:ok, i} =
      Interactions.create_interaction(%{
        "company_uuid" => company.uuid,
        "project_uuid" => project_uuid,
        "interaction_type" => "call",
        "subject" => "Before"
      })

    ctx = %{project: %{uuid: project_uuid}, user_uuid: nil, key: nil, actor: nil}

    # a malformed list is a 422; an unknown task (nothing is within reach here) a 404 — and the row is untouched
    assert {:error, {422, "validation_failed", _, _}} =
             ProjectApi.update(ctx, i.uuid, %{"subject" => "After", "tasks" => [123]})

    assert {:error, {404, "not_found", _, _}} =
             ProjectApi.update(ctx, i.uuid, %{
               "subject" => "After",
               "tasks" => [Ecto.UUID.generate()]
             })

    assert Interactions.get_interaction(i.uuid).subject == "Before"
  end

  test "the interactions list honours since and limit, newest first" do
    {:ok, company} = Companies.create_company(%{"name" => "ANDI"})
    project_uuid = Ecto.UUID.generate()

    for {subject, at} <- [
          {"Old", ~U[2026-10-01 10:00:00Z]},
          {"Mid", ~U[2026-10-03 10:00:00Z]},
          {"New", ~U[2026-10-05 10:00:00Z]}
        ] do
      {:ok, _} =
        Interactions.create_interaction(%{
          "company_uuid" => company.uuid,
          "project_uuid" => project_uuid,
          "interaction_type" => "call",
          "subject" => subject,
          "occurred_at" => at
        })
    end

    ctx = %{project: %{uuid: project_uuid}}
    assert {:ok, %{interactions: all, count: 3, now: %DateTime{}}} = ProjectApi.list(ctx, %{})
    assert Enum.map(all, & &1.subject) == ["New", "Mid", "Old"]
    assert Enum.all?(all, &(&1.tasks == []))

    assert {:ok, %{interactions: [%{subject: "New"}], count: 1}} =
             ProjectApi.list(ctx, %{"limit" => "1"})

    assert {:ok, %{interactions: since, count: 2}} =
             ProjectApi.list(ctx, %{"since" => "2026-10-02T00:00:00Z"})

    assert Enum.map(since, & &1.subject) == ["New", "Mid"]
  end
end
