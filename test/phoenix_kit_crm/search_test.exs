defmodule PhoenixKitCRM.SearchTest do
  use ExUnit.Case, async: true

  alias PhoenixKitCRM.Search

  describe "like_pattern/1" do
    test "wraps the term in %…%" do
      assert Search.like_pattern("acme") == "%acme%"
    end

    test "escapes LIKE metacharacters so they match literally" do
      assert Search.like_pattern("100%_\\") == "%100\\%\\_\\\\%"
    end

    test "trims leading/trailing whitespace" do
      assert Search.like_pattern("  acme  ") == "%acme%"
    end

    test "strips NUL bytes (Postgres rejects 0x00 in text parameters)" do
      assert Search.like_pattern("a" <> <<0>> <> "b") == "%ab%"
    end
  end
end
