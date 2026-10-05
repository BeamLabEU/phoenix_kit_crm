defmodule PhoenixKitCRM.StaffLink do
  # `apply/3` is used deliberately so the optional `phoenix_kit_staff` dep
  # (not in this module's deps) doesn't trip compile-time "undefined function"
  # warnings; `function_exported?/3` gates every call. Hence the Apply opt-out.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Optional, soft integration with `phoenix_kit_staff`. Everything here is
  guarded — the CRM module works whether or not the staff module is present
  or enabled. Used by the interaction "involved parties" picker (a staff
  person can be selected) and by the party snapshot.
  """

  require Logger

  @doc "Whether the staff module is loaded AND enabled. Always safe to call."
  @spec enabled?() :: boolean()
  def enabled? do
    Code.ensure_loaded?(PhoenixKitStaff) and
      function_exported?(PhoenixKitStaff, :enabled?, 0) and
      apply(PhoenixKitStaff, :enabled?, [])
  rescue
    _ -> false
  end

  @doc "Path to a staff person's profile page, or nil when staff is unavailable."
  @spec person_path(binary()) :: String.t() | nil
  def person_path(staff_person_uuid) when is_binary(staff_person_uuid) do
    if enabled?() and Code.ensure_loaded?(PhoenixKitStaff.Paths) and
         function_exported?(PhoenixKitStaff.Paths, :person, 1) do
      apply(PhoenixKitStaff.Paths, :person, [staff_person_uuid])
    end
  rescue
    _ -> nil
  end

  def person_path(_), do: nil

  @doc """
  Searches staff people by name (case-insensitive) when staff is enabled.
  Returns a list of `%{uuid, name, job_title}` maps. Empty when staff is off.
  """
  @spec search(String.t(), pos_integer()) :: [map()]
  def search(query, limit \\ 8) when is_binary(query) do
    q = String.trim(query)

    if enabled?() and q != "" and Code.ensure_loaded?(PhoenixKitStaff.Staff) and
         function_exported?(PhoenixKitStaff.Staff, :list_people, 1) do
      down = String.downcase(q)

      apply(PhoenixKitStaff.Staff, :list_people, [[]])
      |> Enum.filter(fn p -> String.contains?(String.downcase(person_name(p)), down) end)
      |> Enum.take(limit)
      |> Enum.map(&to_result/1)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[CRM] StaffLink.search error: #{Exception.message(e)}")
      []
  end

  @doc """
  The staff person linked to a user, as `%{uuid, name, job_title}`, or nil
  when staff is off or the user has no staff record.
  """
  @spec person_for_user(binary()) :: map() | nil
  def person_for_user(user_uuid) when is_binary(user_uuid) do
    if enabled?() and Code.ensure_loaded?(PhoenixKitStaff.Staff) and
         function_exported?(PhoenixKitStaff.Staff, :get_person_by_user_uuid, 2) do
      case apply(PhoenixKitStaff.Staff, :get_person_by_user_uuid, [user_uuid, [preload: []]]) do
        nil -> nil
        person -> to_result(person)
      end
    end
  rescue
    e ->
      Logger.warning("[CRM] StaffLink.person_for_user error: #{Exception.message(e)}")
      nil
  end

  def person_for_user(_), do: nil

  @doc """
  Builds an as-of-now profile snapshot for a staff person, for freezing onto
  an interaction party. Returns `%{}` if staff is unavailable or unknown.
  """
  @spec snapshot(UUIDv7.t() | String.t()) :: map()
  def snapshot(staff_person_uuid) when is_binary(staff_person_uuid) do
    if enabled?() and Code.ensure_loaded?(PhoenixKitStaff.Staff) and
         function_exported?(PhoenixKitStaff.Staff, :get_person, 1) do
      case apply(PhoenixKitStaff.Staff, :get_person, [staff_person_uuid]) do
        nil -> %{}
        person -> build_snapshot(person)
      end
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("[CRM] StaffLink.snapshot error: #{Exception.message(e)}")
      %{}
  end

  defp build_snapshot(person) do
    %{
      "source" => "staff",
      "name" => person_name(person),
      "job_title" => safe(person, :job_title),
      "employment_type" => safe(person, :employment_type)
    }
    |> drop_nils()
  end

  defp to_result(p) do
    %{uuid: safe(p, :uuid), name: person_name(p), job_title: safe(p, :job_title)}
  end

  defp person_name(p) do
    if Code.ensure_loaded?(PhoenixKitStaff.Schemas.Person) and
         function_exported?(PhoenixKitStaff.Schemas.Person, :display_name, 1) do
      apply(PhoenixKitStaff.Schemas.Person, :display_name, [p])
    else
      safe(p, :name) || "Unnamed"
    end
  end

  defp safe(struct, key), do: Map.get(struct, key)

  defp drop_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
