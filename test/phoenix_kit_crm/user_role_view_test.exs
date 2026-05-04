defmodule PhoenixKitCRM.UserRoleViewTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitCRM.UserRoleView

  describe "scope_to_string/1" do
    test "encodes :organizations as \"organizations\"" do
      assert UserRoleView.scope_to_string(:organizations) == "organizations"
    end

    test "encodes {:role, uuid} as \"role:<uuid>\"" do
      assert UserRoleView.scope_to_string({:role, "abc-123"}) == "role:abc-123"
    end
  end

  describe "scope_from_string/1" do
    test "decodes \"organizations\"" do
      assert UserRoleView.scope_from_string("organizations") == :organizations
    end

    test "decodes \"role:<uuid>\"" do
      assert UserRoleView.scope_from_string("role:abc-123") == {:role, "abc-123"}
    end

    test "falls back to :organizations and logs a warning on malformed input" do
      log =
        capture_log(fn ->
          assert UserRoleView.scope_from_string("garbage") == :organizations
        end)

      assert log =~ "Unknown scope string"
    end
  end

  describe "scope round-trip" do
    test "every encoded scope decodes back to the original term" do
      for scope <- [
            :organizations,
            {:role, "uuid-1"},
            {:role, "00000000-0000-0000-0000-000000000000"}
          ] do
        assert scope
               |> UserRoleView.scope_to_string()
               |> UserRoleView.scope_from_string() == scope
      end
    end
  end

  describe "default_config/1" do
    test "is an empty map for both scope shapes" do
      assert UserRoleView.default_config(:organizations) == %{}
      assert UserRoleView.default_config({:role, "uuid"}) == %{}
    end
  end
end
