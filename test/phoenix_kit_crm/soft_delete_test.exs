defmodule PhoenixKitCRM.SoftDeleteTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Contacts, SoftDelete}

  @sentinel "trashed"

  defp contact! do
    {:ok, c} = Contacts.create_contact(%{"name" => "Soft #{System.unique_integer([:positive])}"})
    c
  end

  defp write!(record, changes), do: Repo.update!(Ecto.Changeset.change(record, changes))

  describe "trash/3" do
    test "stashes the current status under trashed_from_status and sets the sentinel" do
      c = contact!() |> write!(status: "inactive", metadata: %{"x" => 1})

      assert {:ok, t} = SoftDelete.trash(Repo, c, @sentinel)
      assert t.status == @sentinel
      assert t.metadata == %{"x" => 1, "trashed_from_status" => "inactive"}
      assert Repo.reload(c).metadata == t.metadata
    end

    test "keeps a key another session wrote after the record was loaded" do
      c = contact!()
      # Another session writes into metadata; `c` still holds the old map.
      write!(c, metadata: %{"avatar_uuid" => "abc"})

      assert {:ok, t} = SoftDelete.trash(Repo, c, @sentinel)
      assert t.metadata == %{"avatar_uuid" => "abc", "trashed_from_status" => "active"}
    end

    test "the second of two sessions trashing the same record is told so" do
      c = contact!()
      assert {:ok, _} = SoftDelete.trash(Repo, c, @sentinel)
      # This copy still reads active — the guard is in the UPDATE, not the struct.
      assert {:error, :already_trashed} = SoftDelete.trash(Repo, c, @sentinel)
    end

    test "a record that is gone answers not_found" do
      c = contact!()
      Repo.delete!(c)
      assert {:error, :not_found} = SoftDelete.trash(Repo, c, @sentinel)
    end
  end

  describe "restore/4" do
    test "restores the stashed status and clears only the stash key" do
      c = contact!() |> write!(status: "inactive", metadata: %{"y" => 2})
      {:ok, t} = SoftDelete.trash(Repo, c, @sentinel)

      assert {:ok, r} = SoftDelete.restore(Repo, t, @sentinel, ["active", "inactive"])
      assert r.status == "inactive"
      assert r.metadata == %{"y" => 2}
      assert Repo.reload(c).metadata == %{"y" => 2}
    end

    test "keeps a key another session wrote while it was trashed" do
      c = contact!()
      {:ok, t} = SoftDelete.trash(Repo, c, @sentinel)
      write!(t, metadata: Map.put(t.metadata, "avatar_uuid", "abc"))

      assert {:ok, r} = SoftDelete.restore(Repo, t, @sentinel, ["active"])
      assert r.status == "active"
      assert r.metadata == %{"avatar_uuid" => "abc"}
    end

    test "falls back to active when the stashed status is no longer valid" do
      c = contact!() |> write!(status: "inactive")
      {:ok, t} = SoftDelete.trash(Repo, c, @sentinel)

      assert {:ok, r} = SoftDelete.restore(Repo, t, @sentinel, ["active"])
      assert r.status == "active"
    end

    test "falls back to active when nothing was stashed" do
      c = contact!() |> write!(status: @sentinel, metadata: %{})

      assert {:ok, r} = SoftDelete.restore(Repo, c, @sentinel, ["active", "inactive"])
      assert r.status == "active"
      assert r.metadata == %{}
    end

    test "a record that is not trashed answers not_trashed" do
      assert {:error, :not_trashed} = SoftDelete.restore(Repo, contact!(), @sentinel, ["active"])
    end
  end
end
