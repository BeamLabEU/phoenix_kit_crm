defmodule PhoenixKitCRM.Web.ProjectClientLiveTest do
  @moduledoc """
  Render tests for the projects-hub Client tab.

  Deliberately DB-free: the tab's crash risk lives in `render/1` (struct field
  access on rows the mount loaded), and the mount's `safe/1` wrapper does not
  extend there — a bad field reference takes down the tab and, since the hub
  renders it as a nested `live_render`, the host project page with it. So the
  template is exercised directly against in-memory structs, no sandbox needed.
  """
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias PhoenixKitCRM.Schemas.{Company, CompanyMembership, Interaction}
  alias PhoenixKitCRM.Web.ProjectClientLive

  @company %Company{
    uuid: "0199a0e0-0000-7000-8000-000000000001",
    name: "Acme Holding",
    status: "active"
  }

  defp render_tab(overrides) do
    %{
      __changed__: nil,
      project_uuid: "0199a0e0-0000-7000-8000-0000000000ff",
      company_uuid: nil,
      company: nil,
      memberships: [],
      recent: [],
      loading: false
    }
    |> Map.merge(Map.new(overrides))
    |> ProjectClientLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "renders each interaction's type label and subject" do
    html =
      render_tab(
        company: @company,
        memberships: [%CompanyMembership{}],
        recent: [
          %Interaction{interaction_type: "call", subject: "Kickoff call"},
          %Interaction{interaction_type: "meeting", subject: nil}
        ]
      )

    assert html =~ "Acme Holding"
    # `interaction_type` is the schema field — there is no `:kind`, and reading
    # one raises a KeyError mid-render (the PR #19 regression this locks).
    assert html =~ Interaction.type_label("call")
    assert html =~ "Kickoff call"
    assert html =~ "(no subject)"
  end

  test "counts member contacts with the right plural form" do
    assert render_tab(company: @company, memberships: [%CompanyMembership{}]) =~
             "1 member contact"

    assert render_tab(company: @company, memberships: List.duplicate(%CompanyMembership{}, 3)) =~
             "3 member contacts"
  end

  test "flags a trashed company rather than presenting it as the live client" do
    html = render_tab(company: %{@company | status: "trashed"}, memberships: [])

    assert html =~ "Acme Holding"
    assert html =~ "Trashed"
  end

  test "falls back to a placeholder initial for a blank company name" do
    assert render_tab(company: %{@company | name: "   "}) =~ "?"
  end

  test "shows the link-a-client empty state when config carries no company" do
    html = render_tab(company: nil)

    assert html =~ "No client linked to this project yet."
    refute html =~ "Recent interactions"
  end

  test "paints a skeleton on the disconnected mount instead of a false empty state" do
    html = render_tab(loading: true)

    assert html =~ "skeleton"
    refute html =~ "No client linked to this project yet."
  end
end
