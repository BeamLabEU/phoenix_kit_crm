defmodule PhoenixKitCRM.Web.Components.MirrorConflictModalTest do
  @moduledoc """
  Render tests for the per-field divergence-resolution modal (owner Q5).
  Presentational component — no DB, no LiveView process,
  `render_component/2` against the function directly.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitCRM.Web.Components.MirrorConflictModal

  describe "with conflicts" do
    test "renders one row per conflict, showing both values and the field name in the radios" do
      conflicts = [
        %{field: :name, label: "Name", crm: "Acme", user: "Acme GmbH"},
        %{field: :email, label: "Email", crm: "a@acme.test", user: "b@acme.test"}
      ]

      html =
        render_component(&MirrorConflictModal.mirror_conflict_modal/1,
          conflicts: conflicts,
          master: :crm,
          show: true
        )

      assert html =~ "Name"
      assert html =~ "Acme GmbH"
      assert html =~ "Email"
      assert html =~ "a@acme.test"
      assert html =~ "b@acme.test"
      assert html =~ ~s(name="choices[name]")
      assert html =~ ~s(name="choices[email]")
      assert html =~ "mirror_resolve"
      assert html =~ "mirror_cancel_conflict"
    end

    test "radios default to the CRM side when master is :crm" do
      conflicts = [%{field: :name, label: "Name", crm: "Acme", user: "Acme GmbH"}]

      html =
        render_component(&MirrorConflictModal.mirror_conflict_modal/1,
          conflicts: conflicts,
          master: :crm,
          show: true
        )

      assert html =~ ~r/value="keep_crm"[^>]*checked/
      refute html =~ ~r/value="keep_user"[^>]*checked/
    end

    test "radios default to the User side when master is :user" do
      conflicts = [%{field: :name, label: "Name", crm: "Acme", user: "Acme GmbH"}]

      html =
        render_component(&MirrorConflictModal.mirror_conflict_modal/1,
          conflicts: conflicts,
          master: :user,
          show: true
        )

      assert html =~ ~r/value="keep_user"[^>]*checked/
      refute html =~ ~r/value="keep_crm"[^>]*checked/
    end

    test "renders two independent rows for a two-field conflict list" do
      conflicts = [
        %{field: :name, label: "Name", crm: "Acme", user: "Acme GmbH"},
        %{field: :email, label: "Email", crm: "a@acme.test", user: "b@acme.test"}
      ]

      html =
        render_component(&MirrorConflictModal.mirror_conflict_modal/1,
          conflicts: conflicts,
          master: :crm,
          show: true
        )

      assert html =~ ~s(data-testid="conflict-row-name")
      assert html =~ ~s(data-testid="conflict-row-email")
    end
  end

  describe "no conflicts" do
    test "renders nothing" do
      html =
        render_component(&MirrorConflictModal.mirror_conflict_modal/1,
          conflicts: [],
          master: :crm,
          show: true
        )

      assert String.trim(html) == ""
    end
  end
end
