defmodule PhoenixKitCRM.ProjectsLinkTest do
  @moduledoc """
  The soft link to the projects module, which is NOT a dependency here:
  every call degrades to nothing or `{:error, :unavailable}`, never a
  raise — the Client tab must render on an install without it.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCRM.ProjectsLink

  test "without the projects module every read is empty and every write says so" do
    refute Code.ensure_loaded?(PhoenixKitProjects.Ledger)
    refute ProjectsLink.available?()
    assert ProjectsLink.list_events(Ecto.UUID.generate()) == []
    assert ProjectsLink.get_event(Ecto.UUID.generate(), Ecto.UUID.generate()) == nil
    assert {:error, :unavailable} = ProjectsLink.log_time(Ecto.UUID.generate(), 5, [])

    assert {:error, :unavailable} =
             ProjectsLink.create_event(Ecto.UUID.generate(), %{
               title: "x",
               starts_at: DateTime.utc_now()
             })
  end
end
