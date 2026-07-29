defmodule PhoenixKitCRM.Web.PartyRoleHelpersTest do
  # Pure helpers — no DB, so a plain ExUnit.Case (async) is enough.
  use ExUnit.Case, async: true

  alias PhoenixKitCRM.Web.PartyRoleHelpers

  describe "selected_roles/1 (forged-payload filtering — the security claim)" do
    test "keeps only known roles" do
      assert PartyRoleHelpers.selected_roles(%{"roles" => ["supplier", "customer"]}) ==
               ["supplier", "customer"]
    end

    test "drops unknown roles and non-string members without raising" do
      assert PartyRoleHelpers.selected_roles(%{"roles" => ["supplier", "admin", %{}, 42]}) ==
               ["supplier"]
    end

    test "handles missing key, scalar, and non-map payloads" do
      assert PartyRoleHelpers.selected_roles(%{}) == []
      assert PartyRoleHelpers.selected_roles(%{"roles" => "supplier"}) == ["supplier"]
      assert PartyRoleHelpers.selected_roles(:not_a_map) == []
    end
  end

  describe "role_label/1 and role_badge_class/1" do
    test "known roles map to labels and badge classes" do
      assert PartyRoleHelpers.role_label("supplier") == "Supplier"
      assert PartyRoleHelpers.role_badge_class("supplier") == "badge-info"
      assert PartyRoleHelpers.role_badge_class("customer") == "badge-success"
    end

    test "unknown role falls through to a neutral badge and its raw value" do
      assert PartyRoleHelpers.role_label("weird") == "weird"
      assert PartyRoleHelpers.role_badge_class("weird") == "badge-ghost"
    end
  end
end
