defmodule PhoenixKitCRM.Web.PartyRoleHelpersTest do
  # Pure helpers — no DB, so a plain ExUnit.Case (async) is enough.
  use ExUnit.Case, async: true

  alias PhoenixKitCRM.Schemas.PartyRoleType
  alias PhoenixKitCRM.Web.PartyRoleHelpers

  # What `form_types/1` hands the form: the types on offer.
  defp offered(keys), do: Enum.map(keys, &%PartyRoleType{key: &1})

  defp types do
    %{
      "supplier" => %PartyRoleType{key: "supplier", builtin: true, badge: "badge-info"},
      "customer" => %PartyRoleType{key: "customer", builtin: true, badge: "badge-success"},
      "carrier" => %PartyRoleType{
        key: "carrier",
        badge: "badge-secondary",
        data: %{"_primary_language" => "en", "en" => %{"name" => "Carrier"}}
      }
    }
  end

  describe "selected_roles/2 (forged-payload filtering — the security claim)" do
    test "keeps only the roles the form offered" do
      assert PartyRoleHelpers.selected_roles(
               %{"roles" => ["supplier", "customer"]},
               offered(["supplier", "customer"])
             ) == ["supplier", "customer"]
    end

    test "a role that exists but was not offered (archived, or forged) is dropped" do
      assert PartyRoleHelpers.selected_roles(
               %{"roles" => ["supplier", "carrier"]},
               offered(["supplier"])
             ) == ["supplier"]
    end

    test "drops unknown roles and non-string members without raising" do
      assert PartyRoleHelpers.selected_roles(
               %{"roles" => ["supplier", "admin", %{}, 42]},
               offered(["supplier"])
             ) == ["supplier"]
    end

    test "handles missing key, scalar, and non-map payloads" do
      offered = offered(["supplier"])
      assert PartyRoleHelpers.selected_roles(%{}, offered) == []
      assert PartyRoleHelpers.selected_roles(%{"roles" => "supplier"}, offered) == ["supplier"]
      assert PartyRoleHelpers.selected_roles(:not_a_map, offered) == []
    end
  end

  describe "role_label/2 and role_badge_class/2" do
    test "built-ins fall back to their gettext label and keep their badge" do
      assert PartyRoleHelpers.role_label(types(), "supplier") == "Supplier"
      assert PartyRoleHelpers.role_badge_class(types(), "supplier") == "badge-info"
      assert PartyRoleHelpers.role_badge_class(types(), "customer") == "badge-success"
    end

    test "a custom role reads its name and badge from its type" do
      assert PartyRoleHelpers.role_label(types(), "carrier", "en") == "Carrier"
      assert PartyRoleHelpers.role_badge_class(types(), "carrier") == "badge-secondary"
    end

    test "unknown role falls through to a neutral badge and its raw value" do
      assert PartyRoleHelpers.role_label(types(), "weird") == "weird"
      assert PartyRoleHelpers.role_badge_class(types(), "weird") == "badge-ghost"
    end

    test "a page with no types loaded still renders a built-in role" do
      assert PartyRoleHelpers.role_label(%{}, "supplier") == "Supplier"
      assert PartyRoleHelpers.role_badge_class(%{}, "supplier") == "badge-ghost"
    end
  end
end
