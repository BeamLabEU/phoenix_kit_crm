defmodule PhoenixKitCRM.Web.InteractionHelpersTzTest do
  @moduledoc """
  The viewer-zone helpers. `viewer_tz/1` needs the DB only for the site
  fallback; the conversions are pure.
  """
  use PhoenixKitCRM.DataCase, async: false

  alias PhoenixKitCRM.Web.InteractionHelpers, as: H

  describe "viewer_tz/1" do
    test "a profile value wins, an IANA id or a legacy offset alike" do
      assert H.viewer_tz(%{user_timezone: "Europe/Tallinn"}) == "Europe/Tallinn"
      assert H.viewer_tz(%{user_timezone: "5.5"}) == "5.5"
    end

    test "no profile value — nil, blank, or a map without the column — is the site setting" do
      site = PhoenixKit.Settings.get_setting("time_zone", "0")
      assert H.viewer_tz(%{user_timezone: nil}) == site
      assert H.viewer_tz(%{user_timezone: ""}) == site
      assert H.viewer_tz(%{uuid: "x"}) == site
      assert H.viewer_tz(nil) == site
    end
  end

  describe "format_local/2" do
    test "an IANA zone follows daylight saving on the date shown" do
      assert H.format_local(~U[2026-01-15 08:00:00Z], "Europe/Tallinn") == "2026-01-15 10:00"
      assert H.format_local(~U[2026-07-15 08:00:00Z], "Europe/Tallinn") == "2026-07-15 11:00"
    end

    test "a legacy offset is fixed, and a fractional one is not truncated" do
      assert H.format_local(~U[2026-07-15 08:00:00Z], "2") == "2026-07-15 10:00"
      assert H.format_local(~U[2026-07-15 08:00:00Z], "5.5") == "2026-07-15 13:30"
      assert H.format_local(nil, "2") == "—"
    end
  end

  describe "offset_minutes_now/1" do
    test "is the zone's offset right now, in minutes, sign included" do
      assert H.offset_minutes_now("0") == 0
      assert H.offset_minutes_now("-5") == -300
      assert H.offset_minutes_now("5.5") == 330
      assert H.offset_minutes_now("Europe/Tallinn") in [120, 180]
    end
  end
end
