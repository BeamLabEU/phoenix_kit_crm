defmodule PhoenixKitCRM.InteractionLinksContextTest do
  @moduledoc """
  A `#` typed inside a project offers that project's interactions, not
  every interaction the viewer may see (Max, 2026-10-05); without a
  context the search is as wide as CRM access allows.
  """

  use PhoenixKitCRM.LiveCase, async: false

  alias PhoenixKitCRM.{Companies, InteractionLinks, Interactions}

  setup do
    # The handler answers only while the module is switched on.
    {:ok, _} = PhoenixKitCRM.enable_system()
    on_exit(fn -> PhoenixKitCRM.disable_system() end)

    {:ok, company} = Companies.create_company(%{"name" => "ANDI"})
    here = Ecto.UUID.generate()
    elsewhere = Ecto.UUID.generate()

    make = fn subject, project ->
      {:ok, i} =
        Interactions.create_interaction(%{
          "company_uuid" => company.uuid,
          "interaction_type" => "meeting",
          "occurred_at" => ~U[2026-10-04 14:00:00Z],
          "subject" => subject,
          "project_uuid" => project
        })

      i
    end

    make.("ANDI kickoff", here)
    make.("ANDI website call", elsewhere)
    make.("ANDI stray note", nil)

    {:ok, scope: fake_scope(), here: here}
  end

  defp titles(results), do: results |> Enum.map(& &1.title) |> Enum.sort()

  test "the context keeps the search inside the project", %{scope: scope, here: here} do
    assert titles(InteractionLinks.search_resources("ANDI", scope: scope)) ==
             ["ANDI kickoff", "ANDI stray note", "ANDI website call"]

    assert titles(
             InteractionLinks.search_resources("ANDI",
               scope: scope,
               context: %{"project" => here}
             )
           ) ==
             ["ANDI kickoff"]

    # a context the viewer may not search from still needs CRM access
    none = fake_scope(permissions: [])

    assert InteractionLinks.search_resources("ANDI", scope: none, context: %{"project" => here}) ==
             []
  end
end
