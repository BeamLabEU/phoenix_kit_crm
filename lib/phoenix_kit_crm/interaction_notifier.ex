defmodule PhoenixKitCRM.InteractionNotifier do
  # `apply/3` on purpose: the fan-out is core's, and an install on an older
  # core must stay a clean no-op (the same gate the projects module uses).
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Tells the people a planned interaction involves that it exists, moved or
  was cancelled (V9). One activity entry is already written by
  `PhoenixKitCRM.Interactions`; this fans that entry out to the users
  behind the parties through core's `Notifications.fan_out_from_activity/2`,
  which applies each recipient's own rules (preferences, channels, digests)
  and skips the actor.

  A party reaches a user through its staff person or its contact (their
  `user_uuid`, read live and schemaless — the staff table belongs to
  another module); a free-text name reaches nobody. Everything here is
  best-effort: the interaction has committed, and a failure to notify must
  never look like a failure to save.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitCRM.Schemas.{Contact, Interaction}

  @notifications PhoenixKit.Notifications

  @doc """
  The users behind an interaction's parties — the staff people's and the
  contacts' linked accounts — each once.
  """
  @spec party_user_uuids(Interaction.t() | [map()]) :: [String.t()]
  def party_user_uuids(%Interaction{parties: parties}) when is_list(parties),
    do: party_user_uuids(parties)

  def party_user_uuids(parties) when is_list(parties) do
    staff = parties |> Enum.map(& &1.staff_person_uuid) |> Enum.reject(&is_nil/1)
    contacts = parties |> Enum.map(& &1.contact_uuid) |> Enum.reject(&is_nil/1)

    Enum.uniq(
      linked_users("phoenix_kit_staff_people", staff) ++
        linked_users(Contact, contacts)
    )
  end

  def party_user_uuids(_), do: []

  defp linked_users(_table, []), do: []

  defp linked_users(table, uuids) do
    from(r in table,
      where: r.uuid in type(^uuids, {:array, UUIDv7}) and r.status != "trashed",
      where: not is_nil(r.user_uuid),
      select: type(r.user_uuid, UUIDv7)
    )
    |> RepoHelper.repo().all()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Fans the committed activity entry out to `user_uuids`. Takes what
  `Activity.log/2` returned, so a log that did not write is a no-op.
  """
  @spec fan_out(term(), [String.t()]) :: :ok
  def fan_out({:ok, %{uuid: _} = entry}, [_ | _] = user_uuids) do
    if Code.ensure_loaded?(@notifications) and
         function_exported?(@notifications, :fan_out_from_activity, 2) do
      apply(@notifications, :fan_out_from_activity, [entry, user_uuids])
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def fan_out(_log_result, _user_uuids), do: :ok
end
