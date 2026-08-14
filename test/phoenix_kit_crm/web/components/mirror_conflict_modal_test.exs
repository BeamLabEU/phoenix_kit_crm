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

    test "an explicit choice for one field wins over @master, while an unset field still defaults to @master" do
      # Regression guard for the controlled-radio fix: this FAILS if
      # `checked` is ever hardcoded back to `@master == :crm/:user` and
      # `@choices` is ignored — master is :crm for both fields here, so a
      # revert would show keep_crm checked on BOTH rows instead of the
      # email row's explicit keep_user choice.
      conflicts = [
        %{field: :name, label: "Name", crm: "Acme", user: "Acme GmbH"},
        %{field: :email, label: "Email", crm: "a@acme.test", user: "b@acme.test"}
      ]

      html =
        render_component(&MirrorConflictModal.mirror_conflict_modal/1,
          conflicts: conflicts,
          master: :crm,
          choices: %{email: :user},
          show: true
        )

      # :name has no entry in @choices — falls back to @master (:crm).
      name_row = row_html(html, "name")
      assert name_row =~ ~r/value="keep_crm"[^>]*checked/
      refute name_row =~ ~r/value="keep_user"[^>]*checked/

      # :email has an explicit choice (:user) that disagrees with @master
      # (:crm) — the explicit choice must win.
      email_row = row_html(html, "email")
      assert email_row =~ ~r/value="keep_user"[^>]*checked/
      refute email_row =~ ~r/value="keep_crm"[^>]*checked/
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

  # Isolates one conflict row's markup (from its own data-testid marker to
  # the next row's marker or end of string) so assertions on `checked`
  # don't accidentally match a sibling row's radio.
  defp row_html(html, field) do
    marker = ~s(data-testid="conflict-row-#{field}")
    [_before, after_marker] = String.split(html, marker, parts: 2)

    case String.split(after_marker, "data-testid=\"conflict-row-", parts: 2) do
      [this_row, _rest] -> this_row
      [this_row] -> this_row
    end
  end
end
