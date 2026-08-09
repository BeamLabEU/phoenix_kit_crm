defmodule PhoenixKitCRM.Search do
  @moduledoc """
  Shared LIKE/ILIKE search-term escaping for contexts that filter by a
  free-text search box (`Contacts`, `Companies`, `PartyRoles`, `Lists`).
  """

  @doc """
  Sanitizes a free-text search term and wraps it in `%…%`, escaping the
  LIKE/ILIKE metacharacters (`\\`, `%`, `_`) so a literal `%` or `_` in the
  term matches itself rather than acting as a wildcard. Postgres ILIKE uses
  backslash as the default escape character.

  Sanitization: NUL bytes are stripped (Postgres rejects 0x00 in text
  parameters with error 22021, so a forged `?search=%00` would otherwise
  crash the query) and the term is trimmed, so `" acme "` behaves like the
  picker searches (`Contacts.search_contacts/3` etc.) rather than silently
  matching nothing.
  """
  def like_pattern(term) when is_binary(term) do
    escaped =
      term
      |> String.replace("\x00", "")
      |> String.trim()
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
  end
end
