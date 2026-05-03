defmodule PhoenixKitCRM.ColumnConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCRM.ColumnConfig

  describe "available_columns/1" do
    test "returns standard companies columns and empty custom map" do
      %{standard: standard, custom: custom} = ColumnConfig.available_columns(:companies)
      assert is_map(standard)
      assert custom == %{}
      assert "name" in Map.keys(standard)
    end

    test "returns standard role columns and empty custom map" do
      %{standard: standard, custom: custom} = ColumnConfig.available_columns({:role, "abc"})
      assert is_map(standard)
      assert custom == %{}
      assert "email" in Map.keys(standard)
    end

    test "ignores the role uuid — same columns for any role" do
      a = ColumnConfig.available_columns({:role, "uuid-a"})
      b = ColumnConfig.available_columns({:role, "uuid-b"})
      assert a == b
    end
  end

  describe "default_columns/1" do
    test "companies defaults are a non-empty subset of standard columns" do
      defaults = ColumnConfig.default_columns(:companies)
      ids = ColumnConfig.all_column_ids(:companies)
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
      assert ColumnConfig.validate_columns(:companies, ["name", "bogus", "tax_id"]) == [
               "name",
               "tax_id"
             ]
    end

    test "preserves order of valid ids" do
      assert ColumnConfig.validate_columns(:companies, ["status", "name", "country"]) == [
               "status",
               "name",
               "country"
             ]
    end

    test "drops everything when nothing matches" do
      assert ColumnConfig.validate_columns(:companies, ["nope", "still_nope"]) == []
    end

    test "empty list passes through" do
      assert ColumnConfig.validate_columns(:companies, []) == []
    end

    test "rejects role columns when scope is companies" do
      assert ColumnConfig.validate_columns(:companies, ["email", "username"]) == []
    end

    test "rejects companies columns when scope is role" do
      assert ColumnConfig.validate_columns({:role, "uuid"}, ["name", "tax_id"]) == []
    end
  end

  describe "get_column_metadata/2" do
    test "returns metadata for a known companies column" do
      assert %{label: _, type: _} = ColumnConfig.get_column_metadata(:companies, "name")
    end

    test "returns nil for an unknown column" do
      assert ColumnConfig.get_column_metadata(:companies, "ghost") == nil
    end

    test "returns metadata for a known role column" do
      assert %{label: _, type: _} = ColumnConfig.get_column_metadata({:role, "uuid"}, "email")
    end
  end
end
