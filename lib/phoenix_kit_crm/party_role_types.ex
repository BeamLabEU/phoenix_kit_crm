defmodule PhoenixKitCRM.PartyRoleTypes do
  @moduledoc """
  The party-role vocabulary as data: what a company or contact can *be* to the
  business. Four built-in types are seeded by migration V10 (`supplier`,
  `manufacturer`, `customer`, `partner`); a host or an admin adds its own
  ("carrier", "forwarder", …) without a release.

  `PhoenixKitCRM.PartyRoles` grants and queries by a type's `key`; this module
  owns the types themselves — listing, creating, relabelling, ordering,
  archiving and deleting them — and the small display helpers (`name/3`,
  `badge_class/2`, `icon/2`) every role-rendering page shares.

  ## Lifecycle

    * **create** — a custom type, with a key that can never change afterwards.
    * **update** — name / description (translated), badge, icon, order.
    * **archive / restore** — an archived type keeps every assignment, badge
      and lookup but is no longer offered for new grants. Built-ins cannot be
      archived.
    * **delete** — only a custom type nobody holds. The FK is
      `ON DELETE RESTRICT`, so a role in use can only be archived.

  ## Hosts that need a role to exist

  `ensure/3` creates a type idempotently, at boot or in a migration, and
  never overwrites what an admin has since edited:

      PhoenixKitCRM.PartyRoleTypes.ensure("carrier",
        names: %{"en" => "Carrier", "et" => "Vedaja", "ru" => "Перевозчик"},
        badge: "badge-secondary",
        icon: "hero-truck"
      )

  ## Display

  Every list page loads `types_by_key/0` once and hands the map to
  `name/3` / `badge_class/2` / `icon/2`, so rendering N badges costs no
  queries. A key with no type (a stray row) renders as its raw key with the
  neutral badge rather than crashing.
  """

  use Gettext, backend: PhoenixKitCRM.Gettext

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCRM.Activity
  alias PhoenixKitCRM.Schemas.{PartyRole, PartyRoleType}

  @type types_map :: %{String.t() => PartyRoleType.t()}

  @fk_name :phoenix_kit_crm_party_roles_role_fkey
  @resource_type "crm_party_role_type"
  @position_step 10

  defp repo, do: RepoHelper.repo()

  # ── Queries ─────────────────────────────────────────────────────────

  @doc """
  Types in display order (position, then creation).

  ## Options
    * `:status` — `:all` (default), `:active` or `:archived`
  """
  @spec list_types(keyword()) :: [PartyRoleType.t()]
  def list_types(opts \\ []) do
    PartyRoleType
    |> filter_status(Keyword.get(opts, :status, :all))
    |> order_by([t], asc: t.position, asc: t.inserted_at, asc: t.key)
    |> repo().all()
  end

  defp filter_status(query, :active), do: where(query, [t], t.status == "active")
  defp filter_status(query, :archived), do: where(query, [t], t.status == "archived")
  defp filter_status(query, _all), do: query

  @doc "Keys of the active types, in display order — the roles a form offers."
  @spec active_keys() :: [String.t()]
  def active_keys do
    PartyRoleType
    |> where([t], t.status == "active")
    |> order_by([t], asc: t.position, asc: t.inserted_at, asc: t.key)
    |> select([t], t.key)
    |> repo().all()
  end

  @doc """
  Every type (archived included) keyed by `key`. Load it once per page and pass
  it to the display helpers — archived types still need their name and badge.
  """
  @spec types_by_key() :: types_map()
  def types_by_key do
    Map.new(list_types(), &{&1.key, &1})
  end

  @doc "A `types_by_key/0` map as a list in display order."
  @spec ordered(types_map()) :: [PartyRoleType.t()]
  def ordered(types) when is_map(types) do
    types |> Map.values() |> Enum.sort_by(&{&1.position, &1.key})
  end

  @spec get_type(String.t()) :: PartyRoleType.t() | nil
  def get_type(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(PartyRoleType, uuid)
      :error -> nil
    end
  end

  def get_type(_), do: nil

  @spec get_type_by_key(String.t()) :: PartyRoleType.t() | nil
  def get_type_by_key(key) when is_binary(key), do: repo().get_by(PartyRoleType, key: key)
  def get_type_by_key(_), do: nil

  @doc "Whether `key` names an active type — the test `grant_role/4` applies."
  @spec active?(term()) :: boolean()
  def active?(key) when is_binary(key) do
    PartyRoleType
    |> where([t], t.key == ^key and t.status == "active")
    |> repo().exists?()
  end

  def active?(_), do: false

  # ── Writes ──────────────────────────────────────────────────────────

  @doc """
  A changeset for the add / edit form: a new type (no uuid yet) validated as a
  creation -- key derived from the name unless given -- a saved one as an
  edit. The primary-language name and description are filled in from `data`
  for the form's primary tab.
  """
  @spec change_type(PartyRoleType.t(), map()) :: Ecto.Changeset.t()
  def change_type(%PartyRoleType{} = type, attrs \\ %{}) do
    type = hydrate(type)
    attrs = stringify_keys(attrs)

    if is_nil(type.uuid),
      do: PartyRoleType.create_changeset(type, attrs),
      else: PartyRoleType.update_changeset(type, attrs)
  end

  @doc "Fills the virtual `name` / `description` from the primary-language `data`."
  @spec hydrate(PartyRoleType.t()) :: PartyRoleType.t()
  def hydrate(%PartyRoleType{} = type) do
    %{
      type
      | name: type.name || name_from_data(type.data),
        description: type.description || field_from_data(type.data, "description", nil)
    }
  end

  @doc """
  Creates a custom type. `attrs` takes `key`, `data` (the translations map —
  see `build_data/2`), `badge`, `icon`, `position`, `status`. `position`
  defaults to the end of the list.

  Pass `:actor_uuid` in `opts` for the activity log.
  """
  @spec create_type(map(), keyword()) :: {:ok, PartyRoleType.t()} | {:error, Ecto.Changeset.t()}
  def create_type(attrs, opts \\ []) do
    attrs = attrs |> stringify_keys() |> Map.put_new_lazy("position", &next_position/0)

    %PartyRoleType{}
    |> PartyRoleType.create_changeset(attrs)
    |> repo().insert()
    |> log_on_ok("crm.party_role_type_created", opts)
  end

  @doc """
  Updates a type's `data`, `badge`, `icon`, `position` or `status`. The key is
  not editable.
  """
  @spec update_type(PartyRoleType.t(), map(), keyword()) ::
          {:ok, PartyRoleType.t()} | {:error, Ecto.Changeset.t()}
  def update_type(%PartyRoleType{} = type, attrs, opts \\ []) do
    type
    |> PartyRoleType.update_changeset(stringify_keys(attrs))
    |> repo().update()
    |> log_on_ok("crm.party_role_type_updated", opts)
  end

  @doc "Archives a type: hidden from new grants, every existing assignment intact."
  @spec archive_type(PartyRoleType.t(), keyword()) ::
          {:ok, PartyRoleType.t()} | {:error, Ecto.Changeset.t()}
  def archive_type(%PartyRoleType{} = type, opts \\ []) do
    type
    |> PartyRoleType.update_changeset(%{"status" => "archived"})
    |> repo().update()
    |> log_on_ok("crm.party_role_type_archived", opts)
  end

  @doc "Makes an archived type grantable again."
  @spec restore_type(PartyRoleType.t(), keyword()) ::
          {:ok, PartyRoleType.t()} | {:error, Ecto.Changeset.t()}
  def restore_type(%PartyRoleType{} = type, opts \\ []) do
    type
    |> PartyRoleType.update_changeset(%{"status" => "active"})
    |> repo().update()
    |> log_on_ok("crm.party_role_type_restored", opts)
  end

  @doc """
  Deletes a custom type nobody holds. A built-in is `{:error, :builtin}`; a
  type some party holds (or once held — revoked rows keep their role) is
  `{:error, :in_use}` and can only be archived.
  """
  @spec delete_type(PartyRoleType.t(), keyword()) ::
          {:ok, PartyRoleType.t()} | {:error, :builtin | :in_use | :not_found}
  def delete_type(type, opts \\ [])

  def delete_type(%PartyRoleType{builtin: true}, _opts), do: {:error, :builtin}

  def delete_type(%PartyRoleType{} = type, opts) do
    if role_rows?(type.key) do
      {:error, :in_use}
    else
      type
      |> Ecto.Changeset.change()
      # The pre-check above is not atomic: a grant landing between it and the
      # DELETE trips the RESTRICT FK, which is the same answer.
      |> Ecto.Changeset.foreign_key_constraint(:key, name: @fk_name, message: "in use")
      |> repo().delete()
      |> case do
        {:ok, deleted} ->
          log_on_ok({:ok, deleted}, "crm.party_role_type_deleted", opts)

        {:error, %Ecto.Changeset{}} ->
          {:error, :in_use}
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  defp role_rows?(key) do
    PartyRole |> where([pr], pr.role == ^key) |> repo().exists?()
  end

  @doc """
  Sets the display order from a list of type uuids: the first gets the lowest
  position. Pass the whole list -- positions are assigned `10, 20, …` to the
  uuids given and types left out keep theirs, so a partial list interleaves
  with them. Unknown uuids are skipped.
  """
  @spec reorder([String.t()], keyword()) :: :ok
  def reorder(uuids, opts \\ []) when is_list(uuids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, :ok} =
      repo().transaction(fn ->
        uuids
        |> Enum.with_index(1)
        |> Enum.each(fn {uuid, index} -> set_position(uuid, index * @position_step, now) end)
      end)

    Activity.log("crm.party_role_types_reordered", actor_uuid: opts[:actor_uuid], metadata: %{})

    :ok
  end

  defp set_position(uuid, position, now) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} ->
        PartyRoleType
        |> where([t], t.uuid == ^uuid)
        |> repo().update_all(set: [position: position, updated_at: now])

      :error ->
        :skip
    end
  end

  @doc """
  Makes sure a type with `key` exists and returns it. Idempotent: an existing
  type (archived or edited by an admin) is returned untouched, never
  overwritten, so it is safe to call on every boot.

  ## Options (in `attrs`, atom or string keys)
    * `:name` — the name in the primary language
    * `:names` — `%{lang => name}`, e.g. `%{"en" => "Carrier", "et" => "Vedaja"}`
    * `:description` / `:descriptions` — likewise
    * `:badge`, `:icon`, `:position` — as on `create_type/2`
    * `:data` — a ready-made translations map, instead of the above
  """
  @spec ensure(String.t(), map() | keyword(), keyword()) ::
          {:ok, PartyRoleType.t()} | {:error, Ecto.Changeset.t()}
  def ensure(key, attrs \\ %{}, opts \\ []) when is_binary(key) do
    case get_type_by_key(key) do
      %PartyRoleType{} = type ->
        {:ok, type}

      nil ->
        key |> ensure_attrs(attrs) |> create_type(opts) |> reconcile_ensure(key)
    end
  end

  defp ensure_attrs(key, attrs) do
    attrs = attrs |> Map.new() |> stringify_keys()

    data =
      Map.get_lazy(attrs, "data", fn ->
        build_data(
          attrs["names"] || attrs["name"],
          attrs["descriptions"] || attrs["description"]
        )
      end)

    attrs
    |> Map.drop(["name", "names", "description", "descriptions"])
    |> Map.merge(%{"key" => key, "data" => data})
  end

  # Two boots racing: the loser sees the winner's row, not an error.
  defp reconcile_ensure({:error, %Ecto.Changeset{errors: errors} = cs}, key) do
    case Keyword.has_key?(errors, :key) && get_type_by_key(key) do
      %PartyRoleType{} = winner -> {:ok, winner}
      _ -> {:error, cs}
    end
  end

  defp reconcile_ensure(result, _key), do: result

  @doc """
  The multilang `data` map for a name (and optional description). A string goes
  under the primary language; a `%{lang => text}` map is stored language by
  language. Blank entries are dropped.
  """
  @spec build_data(String.t() | map() | nil, String.t() | map() | nil) :: map()
  def build_data(names, descriptions \\ nil) do
    host_primary = Multilang.primary_language()
    names = by_language(names, host_primary)
    descriptions = by_language(descriptions, host_primary)

    langs = Enum.uniq(Map.keys(names) ++ Map.keys(descriptions))

    entries =
      for lang <- langs, into: %{} do
        entry =
          %{"_name" => names[lang], "_description" => descriptions[lang]}
          |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
          |> Map.new()

        {lang, entry}
      end

    if entries == %{},
      do: %{},
      else: Map.put(entries, "_primary_language", primary_among(langs, host_primary))
  end

  # The primary entry must be one that exists -- it is the base every other
  # language overrides. The host's primary when given (or its base code:
  # "en" for "en-US"), else the first language given.
  defp primary_among(langs, host_primary) do
    base = DialectMapper.extract_base(host_primary)

    Enum.find(langs, &(&1 == host_primary)) ||
      Enum.find(langs, &(DialectMapper.extract_base(&1) == base)) ||
      hd(Enum.sort(langs))
  end

  defp by_language(nil, _primary), do: %{}

  defp by_language(text, primary) when is_binary(text),
    do: by_language(%{primary => text}, primary)

  defp by_language(%{} = map, _primary) do
    for {lang, text} <- map, is_binary(text), String.trim(text) != "", into: %{} do
      {to_string(lang), String.trim(text)}
    end
  end

  defp by_language(_, _), do: %{}

  @doc """
  A machine key from a name: ASCII letters and digits, lowercased, `_` between
  words, starting with a letter, cut to the key limit. Returns `""` when
  nothing usable is left (a Cyrillic-only name), in which case the caller asks
  for a key.
  """
  @spec derive_key(String.t() | nil) :: String.t()
  def derive_key(nil), do: ""

  def derive_key(name) when is_binary(name) do
    name
    |> String.normalize(:nfd)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.replace(~r/\A[0-9_]+/, "")
    |> String.slice(0, PartyRoleType.key_max())
    |> String.trim_trailing("_")
  end

  # ── Display ─────────────────────────────────────────────────────────

  @doc """
  The type's name in `lang` (default: the viewer's locale), falling back to the
  primary language, then — for a built-in — to its gettext string, then to the
  key.
  """
  @spec name(PartyRoleType.t(), String.t() | nil) :: String.t()
  def name(%PartyRoleType{} = type, lang \\ nil) do
    name_from_data(type.data, lang || locale()) || builtin_name(type.key) || type.key
  end

  @doc """
  `name/2` for a key, looked up in a `types_by_key/0` map. A key with no type
  (a stray row) is its own label.
  """
  @spec label(types_map() | nil, String.t(), String.t() | nil) :: String.t()
  def label(types, key, lang \\ nil) when is_binary(key) do
    case is_map(types) && Map.get(types, key) do
      %PartyRoleType{} = type -> name(type, lang)
      _ -> builtin_name(key) || key
    end
  end

  @doc """
  The label for a tab or card that names a SET of parties ("Suppliers"). The
  built-ins carry gettext plurals; a custom type has only the name it was
  given (Russian and Estonian plurals cannot be derived from one field), and a
  built-in an admin has renamed uses that name too, so the badge and the tab
  never disagree.
  """
  @spec plural_name(types_map() | nil, String.t(), String.t() | nil) :: String.t()
  def plural_name(types, key, lang \\ nil) when is_binary(key) do
    type = is_map(types) && Map.get(types, key)
    renamed = match?(%PartyRoleType{}, type) and name_from_data(type.data, lang || locale())

    cond do
      renamed -> renamed
      plural = builtin_plural(key) -> plural
      true -> label(types, key, lang)
    end
  end

  @doc "The translated description, or `nil`."
  @spec description(PartyRoleType.t(), String.t() | nil) :: String.t() | nil
  def description(%PartyRoleType{} = type, lang \\ nil) do
    field_from_data(type.data, "description", lang || locale())
  end

  @doc "daisyUI badge class for a key; neutral for an unknown one."
  @spec badge_class(types_map() | nil, String.t()) :: String.t()
  def badge_class(types, key) when is_map(types) do
    case Map.get(types, key) do
      %PartyRoleType{badge: badge} -> badge
      nil -> PartyRoleType.default_badge()
    end
  end

  def badge_class(_, _), do: PartyRoleType.default_badge()

  @doc "Heroicon name for a key; the generic tag for an unknown one."
  @spec icon(types_map() | nil, String.t()) :: String.t()
  def icon(types, key) when is_map(types) do
    case Map.get(types, key) do
      %PartyRoleType{icon: icon} -> icon
      nil -> PartyRoleType.default_icon()
    end
  end

  def icon(_, _), do: PartyRoleType.default_icon()

  @doc """
  The name stored in a `data` map: the primary language's, or `lang`'s merged
  over it. `nil` when there is none (a built-in with no override).
  """
  @spec name_from_data(term(), String.t() | nil) :: String.t() | nil
  def name_from_data(data, lang \\ nil), do: field_from_data(data, "name", lang)

  # The multilang form stores `"_name"` (the `_title` convention); data written
  # by hand or by `ensure/3` from a plain map may use the bare `"name"`.
  defp field_from_data(%{} = data, field, lang) do
    entry =
      if lang, do: Multilang.get_language_data(data, lang), else: Multilang.get_primary_data(data)

    value = Map.get(entry, "_" <> field) || Map.get(entry, field)

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  defp field_from_data(_, _, _), do: nil

  # The four seeded roles' names are gettext strings (literal msgids so the
  # extractor sees them); a custom key has none.
  defp builtin_name("supplier"), do: gettext("Supplier")
  defp builtin_name("customer"), do: gettext("Customer")
  defp builtin_name("partner"), do: gettext("Partner")
  defp builtin_name("manufacturer"), do: gettext("Manufacturer")
  defp builtin_name(_), do: nil

  defp builtin_plural("supplier"), do: gettext("Suppliers")
  defp builtin_plural("customer"), do: gettext("Customers")
  defp builtin_plural("partner"), do: gettext("Partners")
  defp builtin_plural("manufacturer"), do: gettext("Manufacturers")
  defp builtin_plural(_), do: nil

  defp locale do
    Multilang.current_locale()
  rescue
    _ -> nil
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp next_position do
    max = PartyRoleType |> select([t], max(t.position)) |> repo().one()
    (max || 0) + @position_step
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp log_on_ok({:ok, %PartyRoleType{} = type} = ok, action, opts) do
    Activity.log(action,
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: @resource_type,
      resource_uuid: type.uuid,
      metadata: %{"key" => type.key}
    )

    ok
  end

  defp log_on_ok(error, _action, _opts), do: error
end
