defmodule PhoenixKitCRM.ColumnConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCRM.ColumnConfig

  describe "available_columns/1" do
    test "returns standard organizations columns and empty custom list" do
      %{standard: standard, custom: custom} = ColumnConfig.available_columns(:organizations)
      assert is_list(standard)
      assert custom == []
      ids = Enum.map(standard, &elem(&1, 0))
      assert "organization_name" in ids
      assert hd(ids) == "organization_name"
    end

    test "returns standard role columns and empty custom list" do
      %{standard: standard, custom: custom} = ColumnConfig.available_columns({:role, "abc"})
      assert is_list(standard)
      assert custom == []
      ids = Enum.map(standard, &elem(&1, 0))
      assert "email" in ids
      assert hd(ids) == "email"
    end

    test "ignores the role uuid — same columns for any role" do
      a = ColumnConfig.available_columns({:role, "uuid-a"})
      b = ColumnConfig.available_columns({:role, "uuid-b"})
      assert a == b
    end
  end

  describe "default_columns/1" do
    test "organizations defaults are a non-empty subset of standard columns" do
      defaults = ColumnConfig.default_columns(:organizations)
      ids = ColumnConfig.all_column_ids(:organizations)
      refute Enum.empty?(defaults)
      assert Enum.all?(defaults, &(&1 in ids))
    end

    test "role defaults are a non-empty subset of standard columns" do
      scope = {:role, "any-uuid"}
      defaults = ColumnConfig.default_columns(scope)
      ids = ColumnConfig.all_column_ids(scope)
      refute Enum.empty?(defaults)
      assert Enum.all?(defaults, &(&1 in ids))
    end
  end

  describe "validate_columns/2" do
    test "filters out unknown ids" do
      assert ColumnConfig.validate_columns(:organizations, [
               "organization_name",
               "bogus",
               "email"
             ]) == ["organization_name", "email"]
    end

    test "preserves order of valid ids" do
      assert ColumnConfig.validate_columns(:organizations, [
               "status",
               "organization_name",
               "email"
             ]) == ["status", "organization_name", "email"]
    end

    test "drops everything when nothing matches" do
      assert ColumnConfig.validate_columns(:organizations, ["nope", "still_nope"]) == []
    end

    test "empty list passes through" do
      assert ColumnConfig.validate_columns(:organizations, []) == []
    end

    test "rejects role-only columns when scope is organizations" do
      assert ColumnConfig.validate_columns(:organizations, ["last_confirmed"]) == []
    end

    test "rejects organization-only columns when scope is role" do
      assert ColumnConfig.validate_columns({:role, "uuid"}, ["organization_name"]) == []
    end
  end

  describe "get_column_metadata/2" do
    test "returns metadata for a known organizations column" do
      assert %{label: _, type: _} =
               ColumnConfig.get_column_metadata(:organizations, "organization_name")
    end

    test "returns nil for an unknown column" do
      assert ColumnConfig.get_column_metadata(:organizations, "ghost") == nil
    end

    test "returns metadata for a known role column" do
      assert %{label: _, type: _} = ColumnConfig.get_column_metadata({:role, "uuid"}, "email")
    end
  end
end
